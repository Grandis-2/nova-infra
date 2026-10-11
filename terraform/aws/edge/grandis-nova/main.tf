# 캐시·원본 요청 정책은 AWS 관리형을 쓴다.
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${local.name_prefix} api"
  price_class     = var.price_class
  aliases         = local.aliases
  web_acl_id      = aws_wafv2_web_acl.cloudfront.arn
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = "api"
    domain_name = local.origin_host

    # 이 헤더가 없으면 ALB 가 404 를 돌려준다 (ecs 스택의 리스너 규칙)
    custom_header {
      name  = local.origin_verify.name
      value = local.origin_verify.value
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.origin_over_https ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = "api"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # API 응답은 캐시하지 않는다. 재고나 대기 순번이 지난 값으로 보이면 안 된다.
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_domain ? null : true
    acm_certificate_arn            = local.use_domain ? local.cloudfront_certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }

  logging_config {
    bucket          = "${local.log_bucket.id}.s3.amazonaws.com"
    prefix          = "cloudfront/"
    include_cookies = false
  }

  tags = { Name = "${local.name_prefix}-cdn" }

  lifecycle {
    # ALB 보안 그룹은 CloudFront 대역에 포트 하나만 연다 (security 스택의 alb_origin_https).
    # 포트가 어긋나면 오류 없이 모든 요청이 시간 초과로 끝나므로 apply 를 막는다.
    # 인증서가 없으면 도메인 없이 조용히 만들어지므로 막는다
    precondition {
      condition     = !local.use_domain || local.cloudfront_certificate_arn != ""
      error_message = "domain_name ${var.domain_name} 을 쓰려면 acm 스택의 CloudFront 인증서가 있어야 합니다. acm 스택을 먼저 apply 하세요."
    }
    precondition {
      condition     = data.terraform_remote_state.security.outputs.alb_origin_port == (local.origin_over_https ? 443 : 80)
      error_message = "CloudFront → ALB 포트가 security 스택과 다릅니다. security 의 alb_origin_https 를 ${local.origin_over_https} 로 바꿔 먼저 적용하세요."
    }
  }
}
