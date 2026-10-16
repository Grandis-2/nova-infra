# ─────────────────────────────────────────────────────────────
# Atlantis — atlantis.<도메인> → CloudFront(edge 스택, Host 를 그대로 넘긴다) → 이 ALB 443
#   → 리스너 규칙(Host + 원본 확인 헤더) → Atlantis 태스크 4141
#
# 태스크 · 서비스는 atlantis-deploy 저장소가 만들고, 이 대상 그룹에 붙인다(출력 atlantis_target_group_arn).
# 전용 ALB 를 두지 않아 ALB 시간 요금과 공인 IP 둘을 아낀다. 웹 UI 는 Atlantis 의 Basic 인증, 웹훅은 GitHub 서명으로 지킨다.
# ─────────────────────────────────────────────────────────────

locals {
  atlantis_domain  = try(data.terraform_remote_state.acm.outputs.atlantis_domain_name, "")
  atlantis_enabled = local.atlantis_domain != "" && local.alb_certificate_arn != ""
}

# 리스너 기본 인증서는 API 것이다. Atlantis 이름은 SNI 로 더 붙인다
resource "aws_lb_listener_certificate" "atlantis" {
  count = local.atlantis_enabled ? 1 : 0

  listener_arn    = aws_lb_listener.https[0].arn
  certificate_arn = data.terraform_remote_state.acm.outputs.atlantis_alb_certificate_arn
}

resource "aws_lb_target_group" "atlantis" {
  count = local.atlantis_enabled ? 1 : 0

  name        = "${local.name_prefix}-atlantis"
  port        = 4141
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  deregistration_delay = 10

  health_check {
    enabled             = true
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name_prefix}-atlantis", Service = "atlantis" }
}

# Grafana(1) · 브라우저 수집(2) 다음, 서비스 규칙(10~90) 앞. Host 로 가르므로 API 와 겹치지 않는다
resource "aws_lb_listener_rule" "atlantis" {
  count = local.atlantis_enabled ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 3

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlantis[0].arn
  }

  condition {
    host_header {
      values = [local.atlantis_domain]
    }
  }

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [random_password.origin_verify.result]
    }
  }

  tags = { Name = "${local.name_prefix}-atlantis" }

  depends_on = [aws_lb_listener_certificate.atlantis]
}
