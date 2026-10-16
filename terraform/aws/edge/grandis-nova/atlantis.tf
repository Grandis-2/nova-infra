# ─────────────────────────────────────────────────────────────
# Atlantis — atlantis.<도메인> → 이 CloudFront → 메인 ALB(ecs 스택 atlantis.tf) → Atlantis 태스크
#
# Grafana 배포와 같이 Host 를 그대로 넘긴다. ALB 는 Atlantis 인증서(ecs 스택이 SNI 로 붙임)를 내주고 Host 로 가른다.
# DNS 레코드는 atlantis-deploy 저장소가 이 배포를 가리키게 바꾼다(지금은 그쪽 전용 ALB 를 가리킨다).
# WAF 는 붙이지 않는다. 웹 UI 는 Basic 인증, 웹훅(/events)은 GitHub 서명으로 Atlantis 가 확인하고,
# 관리형 규칙이 웹훅 본문(코드 · plan 출력)을 공격으로 오인할 수 있다.
# ─────────────────────────────────────────────────────────────

locals {
  atlantis_domain  = try(data.terraform_remote_state.acm.outputs.atlantis_domain_name, "")
  atlantis_enabled = local.atlantis_domain != "" && local.origin_over_https
}

resource "aws_cloudfront_distribution" "atlantis" {
  #checkov:skip=CKV_AWS_68:웹 UI 는 Basic 인증, 웹훅은 GitHub 서명으로 Atlantis 가 확인한다. 관리형 규칙이 웹훅 본문을 오탐한다
  count = local.atlantis_enabled ? 1 : 0

  enabled         = true
  comment         = "${local.name_prefix} atlantis"
  price_class     = var.price_class
  aliases         = [local.atlantis_domain]
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = "alb"
    domain_name = local.origin_host

    custom_header {
      name  = local.origin_verify.name
      value = local.origin_verify.value
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https" # 사람이 주소창에 치므로 http 도 받아 넘긴다
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_with_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.terraform_remote_state.acm.outputs.atlantis_cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = "${local.log_bucket.id}.s3.amazonaws.com"
    prefix          = "cloudfront-atlantis/"
    include_cookies = false
  }

  tags = { Name = "${local.name_prefix}-atlantis" }
}
