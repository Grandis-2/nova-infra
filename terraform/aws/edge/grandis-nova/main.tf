# 원본 요청 · 응답 헤더 정책과 기본 캐시 정책(캐시 안 함)은 AWS 관리형을 쓴다. 공개 조회 캐시 정책만 직접 만든다(아래 public_api).
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

# 공개 조회 캐시 — cache_paths.yml 의 경로만. 캐시 시간은 원본(be)의 Cache-Control 을 따르고, 원본이 정하지 않으면 캐시하지 않는다(기본 0).
# 키는 경로 + 쿼리 전부 + Origin. 응답이 Vary: Origin(CORS)인데 CloudFront 는 Vary 를 보지 않으므로 Origin 을 키에 넣어야
# 다른 오리진에 엉뚱한 CORS 헤더가 가지 않는다. Authorization 은 키에 넣지 않는다 — be 가 로그인과 상관없이 같은 응답에만 public 을 붙인다.
# 원본 요청 정책은 기본 동작과 같아서(모든 헤더 · 쿼리 · 쿠키) 캐시가 비었을 때 원본이 받는 요청은 지금과 같다.
locals {
  cache_paths = yamldecode(file("${path.module}/cache_paths.yml"))
}

resource "aws_cloudfront_cache_policy" "public_api" {
  name        = "${local.name_prefix}-public-api"
  comment     = "Public GET APIs. TTL follows origin Cache-Control (max 5 min)"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 300 # be 가 주는 가장 긴 값(카테고리 5분)

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    query_strings_config {
      query_string_behavior = "all"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Origin"]
      }
    }

    cookies_config {
      cookie_behavior = "none"
    }
  }
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

  # 공개 조회만 원본의 Cache-Control 대로 캐시한다(위 public_api). 순서대로 맞춰 보므로 넓은 패턴이 앞을 가리지 않게 파일 순서를 지킨다
  dynamic "ordered_cache_behavior" {
    for_each = local.cache_paths

    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "api"
      viewer_protocol_policy = "https-only"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id            = aws_cloudfront_cache_policy.public_api.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    }
  }

  # 원본이 Cache-Control 없이 돌려준 5xx(ALB 가 만든 502 · 503 · 504 등)를 CloudFront 는 기본 10초 캐시한다.
  # 캐시 동작이 생기면 장애가 풀린 뒤에도 10초 동안 오류를 돌려주게 되므로 오류는 캐시하지 않는다
  dynamic "custom_error_response" {
    for_each = [500, 502, 503, 504]

    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
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
