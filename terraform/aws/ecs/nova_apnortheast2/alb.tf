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

# HTTP 는 HTTPS 로 넘긴다. 인증서가 없으면 HTTP 로 그대로 서비스한다.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.alb_certificate_arn == "" ? [] : [1]

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.alb_certificate_arn == "" ? [1] : []

    content {
      type = "fixed-response"

      # 어떤 규칙에도 걸리지 않은 경로는 그냥 404. 기본 서비스를 두지 않는다.
      fixed_response {
        content_type = "application/json"
        message_body = "{\"message\":\"not found\"}"
        status_code  = "404"
      }
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
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

locals {
  origin_verify_header = "X-Origin-Verify"

  # 인증서가 있으면 HTTPS 리스너에, 없으면 HTTP 리스너에 규칙을 건다
  routing_listener_arn = local.alb_certificate_arn == "" ? aws_lb_listener.http.arn : aws_lb_listener.https[0].arn
}
