# ─────────────────────────────────────────────────────────────
# Grafana 공개 (NV-517) — grafana.<도메인> → 이 CloudFront → ALB(Cognito 인증) → Grafana
#
# API 배포와 따로 둔다. ALB 의 authenticate-cognito 는 로그인 뒤 돌아올 주소를 Host 로 만드는데,
# API 배포는 Host 를 넘기지 않는다(AllViewerExceptHostHeader). 이 배포는 Host · 쿠키 · 쿼리를 모두 넘긴다.
# 원본은 API 와 같은 origin.<도메인>(ALB). Host 를 넘기면 CloudFront 는 그 이름으로 SNI · 인증서 검증을 하므로
# ALB 는 grafana 인증서(monitoring/lgtm 스택이 SNI 로 붙임)를 내준다.
#
# WAF 는 붙이지 않는다. 앞에서 Cognito 가 막고, 관리형 규칙이 PromQL · LogQL 요청 본문을 공격으로 오인할 수 있다.
# 리스너 규칙(monitoring/lgtm)이 Host 와 원본 확인 헤더를 함께 보므로 이 헤더를 붙인다.
# ─────────────────────────────────────────────────────────────

locals {
  grafana_domain  = data.terraform_remote_state.acm.outputs.grafana_domain_name
  grafana_enabled = local.grafana_domain != "" && local.origin_over_https
}

data "aws_cloudfront_origin_request_policy" "all_viewer_with_host" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "grafana" {
  #checkov:skip=CKV_AWS_68:Cognito(ALB authenticate-cognito) 가 앞에서 막는다. 관리형 규칙이 PromQL · LogQL 본문을 오탐한다
  count = local.grafana_enabled ? 1 : 0

  enabled         = true
  comment         = "${local.name_prefix} grafana"
  price_class     = var.price_class
  aliases         = [local.grafana_domain]
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
      origin_read_timeout    = 60 # 긴 조회(Loki · Tempo)는 Grafana 쪽 시간 초과가 먼저 끝낸다
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
    acm_certificate_arn      = data.terraform_remote_state.acm.outputs.grafana_cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = "${local.log_bucket.id}.s3.amazonaws.com"
    prefix          = "cloudfront-grafana/"
    include_cookies = false
  }

  tags = { Name = "${local.name_prefix}-grafana" }

  lifecycle {
    precondition {
      condition     = data.terraform_remote_state.acm.outputs.grafana_cloudfront_certificate_arn != ""
      error_message = "acm 스택의 grafana CloudFront 인증서가 없습니다. acm 스택을 먼저 apply 하세요."
    }
  }
}

resource "aws_route53_record" "grafana" {
  for_each = local.grafana_enabled ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.route53_zone_id
  name    = local.grafana_domain
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.grafana[0].domain_name
    zone_id                = aws_cloudfront_distribution.grafana[0].hosted_zone_id
    evaluate_target_health = false
  }
}
