# ─────────────────────────────────────────────────────────────
# Grafana 공개 (NV-517)
#
#   grafana.<도메인> → CloudFront(edge 스택, Host 를 그대로 넘긴다) → ALB(ecs 스택) 443
#     → 이 리스너 규칙: Cognito 로그인(authenticate-cognito) → Grafana 3000
#
# 규칙은 Host 와 원본 확인 헤더가 모두 맞아야 걸린다. 아니면 ALB 기본 동작(404)이다.
# Grafana 도 같은 Cognito 풀로 OAuth 로그인한다(main.tf) — ALB 에서 로그인했으므로 비밀번호를 다시 묻지 않는다.
# ─────────────────────────────────────────────────────────────

locals {
  grafana_domain = data.terraform_remote_state.acm.outputs.grafana_domain_name
  grafana_url    = "https://${local.grafana_domain}"
  cognito        = data.terraform_remote_state.cognito.outputs
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.terraform_remote_state.ecs.outputs.alb_arn
  port              = 443
}

data "aws_subnet" "obs" {
  id = data.terraform_remote_state.ecs.outputs.obs_subnet_id
}

# 리스너 기본 인증서는 API 것이다. Grafana 이름은 SNI 로 더 붙인다
resource "aws_lb_listener_certificate" "grafana" {
  listener_arn    = data.aws_lb_listener.https.arn
  certificate_arn = data.terraform_remote_state.acm.outputs.grafana_alb_certificate_arn
}

resource "aws_lb_target_group" "grafana" {
  name        = "${local.name_prefix}-grafana"
  port        = local.obs_ports.grafana
  protocol    = "HTTP"
  vpc_id      = data.aws_subnet.obs.vpc_id
  target_type = "ip"

  deregistration_delay = 10

  # 대상이 unhealthy 면 ECS 가 태스크를 내린다. 이 태스크는 Collector · Loki · Tempo · Mimir 를 같이 들고 있어서,
  # Grafana 가 잠깐 재시작(restartPolicy)한 것으로 관측 전체가 내려가지 않게 느슨하게 본다(약 5분)
  health_check {
    enabled             = true
    path                = "/api/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 10
  }

  tags = { Name = "${local.name_prefix}-grafana", Service = "obs" }
}

# 서비스 규칙(application/*/service.yml, 10~90)보다 먼저 본다. 경로가 아니라 Host 로 가르므로 API 와 겹치지 않는다
resource "aws_lb_listener_rule" "grafana" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 1

  action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = local.cognito.user_pool_arn
      user_pool_client_id        = local.cognito.alb_client_id
      user_pool_domain           = local.cognito.domain
      scope                      = "openid email"
      session_timeout            = 28800 # 8시간
      on_unauthenticated_request = "authenticate"
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = [local.grafana_domain]
    }
  }

  condition {
    http_header {
      http_header_name = data.terraform_remote_state.ecs.outputs.origin_verify_header.name
      # remote state 로 읽은 값은 sensitive 표시가 풀려 plan(Atlantis PR 댓글)에 그대로 찍힌다. 다시 가린다
      values = [sensitive(data.terraform_remote_state.ecs.outputs.origin_verify_header.value)]
    }
  }

  tags = { Name = "${local.name_prefix}-grafana" }

  # SNI 인증서가 붙은 뒤에 규칙을 연다
  depends_on = [aws_lb_listener_certificate.grafana]
}
