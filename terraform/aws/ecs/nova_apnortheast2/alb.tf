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

# ALB 가 직접 끝내는 응답. 앱의 ApiResponse 실패 봉투와 같은 모양이고, 코드는 앱(CommonErrorCode)과 같은 이름이다.
# 앱을 거치지 않았다는 표시로 details.source 를 둔다. 고정 응답이라 timestamp · traceId 는 null 이고 헤더(CORS)는 붙일 수 없다
locals {
  alb_errors = {
    not_found = { code = "NOT_FOUND", message = "Not found." }
    forbidden = { code = "FORBIDDEN", message = "Forbidden." }
  }
  alb_error_body = { for k, v in local.alb_errors : k => jsonencode({
    success   = false
    data      = null
    error     = { code = v.code, message = v.message, details = { source = "edge" } }
    timestamp = null
    traceId   = null
  }) }
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

    # 어떤 규칙에도 걸리지 않은 경로는 404. 기본 서비스를 두지 않는다(서비스는 자기 자원 경로만 받는다)
    fixed_response {
      content_type = "application/json"
      message_body = local.alb_error_body.not_found
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
      message_body = local.alb_error_body.not_found
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

# ── 목업 관리 경로 ────────────────────────────────────────
# 목업(application/mock)의 /external* 는 바깥에서 부를 수 있게 열었다. 그중 지연 · 실패 설정, 결함 주입, 기록 초기화는
# 인증이 없어 프런트(관리자 Mock 설정 화면)에서 온 요청만 목업으로 보내고 나머지는 403 으로 막는다.
#   58 프런트 Origin 이면 목업으로 → 59 그 밖은 403 → 60 목업의 /external* (service.yml)
# Origin 은 클라이언트가 넣는 헤더라 curl 로 흉내 낼 수 있다. 실수로 부르는 것을 막는 장치이고 인증이 아니다.
# worker 는 Service Connect 로 부르므로 이 규칙들을 지나지 않는다.
locals {
  mock_admin_paths          = ["/external/config*", "/external/faults*", "/external/reset*"]
  mock_admin_allow_priority = 58
  mock_admin_block_priority = 59
}

# ALB 규칙 하나의 조건 값은 5개까지다: 경로 3 + Origin 1 + 원본 확인 헤더 1
resource "aws_lb_listener_rule" "mock_admin_from_frontend" {
  listener_arn = local.routing_listener_arn
  priority     = local.mock_admin_allow_priority

  action {
    type             = "forward"
    target_group_arn = module.service["mock"].target_group_arns["0-blue"]
  }

  condition {
    path_pattern {
      values = local.mock_admin_paths
    }
  }

  condition {
    http_header {
      http_header_name = "Origin"
      values           = [var.mock_admin_allowed_origin]
    }
  }

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [random_password.origin_verify.result]
    }
  }

  tags = { Service = "mock" }

  lifecycle {
    precondition {
      condition     = !contains(local._all_priorities, local.mock_admin_allow_priority)
      error_message = "서비스 route priority 가 목업 관리 경로 허용 규칙(58)과 겹친다. service.yml 의 priority 를 바꾼다."
    }
  }
}

resource "aws_lb_listener_rule" "mock_admin_block" {
  listener_arn = local.routing_listener_arn
  priority     = local.mock_admin_block_priority

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = local.alb_error_body.forbidden
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = local.mock_admin_paths
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
