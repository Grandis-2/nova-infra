# ALB 와 리스너. 서비스별 타깃 그룹 · 경로 규칙은 서비스 모듈(_modules/service/alb.tf)이 만든다
resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = local.public_subnets
  security_groups    = [local.alb_sg_id]

  idle_timeout               = 65 # CloudFront origin_read_timeout(60초)보다 길게
  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.enable_alb_access_logs ? [1] : []

    content {
      bucket  = local.log_bucket
      prefix  = "alb"
      enabled = true
    }
  }

  tags = { Name = "${local.name_prefix}-alb" }
}

# 인증서가 없을 때만 HTTP 로 서비스한다 (CloudFront 가 HTTP 로 원본에 붙는 경우).
# 인증서가 있으면 ALB 보안 그룹이 CloudFront 의 443 만 받으므로 80 리스너는 닿을 수 없어 만들지 않는다.
# 사용자 쪽은 CloudFront 가 HTTPS 만 받는다 (edge 스택 viewer_protocol_policy).
resource "aws_lb_listener" "http" {
  count = local.alb_certificate_arn == "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    # 어떤 규칙에도 걸리지 않은 경로는 그냥 404. 기본 서비스를 두지 않는다.
    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.alb_certificate_arn == "" ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.alb_certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"not found\"}"
      status_code  = "404"
    }
  }
}

# ── 원본 검증 헤더 ───────────────────────────────────────────
# ALB 보안 그룹은 CloudFront IP 대역만 허용하지만, 이 대역은 모든 CloudFront 배포가 공유한다.
# 남의 배포로도 ALB 에 닿을 수 있으므로 우리 배포만 아는 헤더(edge 스택)가 없으면 404 를 준다.
#
# 값을 바꿀 때는 keepers.rotation 을 올린다. 이 스택을 apply 한 뒤 edge · monitoring/lgtm 을 다시 plan 해서 apply 한다
# (그 사이 CloudFront 가 옛 값을 보내 API 가 404 다). 이 값을 remote state 로 읽는 스택은 sensitive() 로 감싸야
# 공개 PR 의 plan 댓글에 찍히지 않는다. 1 → 2: PR 댓글에 값이 드러나 교체했다
resource "random_password" "origin_verify" {
  length  = 40
  special = false

  keepers = {
    rotation = 2
  }
}

locals {
  origin_verify_header = "X-Origin-Verify"

  # 인증서가 있으면 HTTPS 리스너에, 없으면 HTTP 리스너에 규칙을 건다
  routing_listener_arn = local.alb_certificate_arn == "" ? aws_lb_listener.http[0].arn : aws_lb_listener.https[0].arn
}

# ── 목업 관리 경로 막기 ──────────────────────────────────────
# 목업(application/mock)의 /external* 는 바깥에서 부를 수 있게 열었다. 그중 지연 · 실패 설정, 결함 주입, 기록 초기화는
# 인증이 없어 막는다. worker 는 Service Connect 로 부르므로 이 규칙을 지나지 않는다.
# 목업 경로 규칙(priority 60)보다 먼저 걸리도록 우선순위를 앞에 둔다.
locals {
  mock_admin_block_priority = 59
}

resource "aws_lb_listener_rule" "mock_admin_block" {
  listener_arn = local.routing_listener_arn
  priority     = local.mock_admin_block_priority

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"message\":\"forbidden\"}"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/external/config*", "/external/faults*", "/external/reset*"]
    }
  }

  tags = { Service = "mock" }

  lifecycle {
    precondition {
      condition     = !contains(local._all_priorities, local.mock_admin_block_priority)
      error_message = "서비스 route priority 가 목업 관리 경로 차단 규칙(59)과 겹친다. service.yml 의 priority 를 바꾼다."
    }
  }
}
