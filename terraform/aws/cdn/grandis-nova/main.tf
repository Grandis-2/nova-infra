# ─────────────────────────────────────────────────────────────
# cdn — 업로드 이미지 조회 (cdn.grandis-nova.link → S3 업로드 버킷)
#
#   업로드 : 브라우저 → API(catalog) → 버킷 PutObject (catalog 태스크 역할)
#   조회   : 브라우저 → CloudFront → 버킷 (OAC, 버킷은 비공개)
#
# WAF 는 붙이지 않는다. 읽기 전용 정적 객체라 막을 앱 로직이 없고, Web ACL 은
# 요청이 없어도 월 고정비($5 + 규칙당 $1)가 든다. DDoS 는 Shield Standard 가 막는다.
# 남은 위험(핫링크, 대량 다운로드로 인한 전송 요금)은 예산 경보로 본다.
#
# edge 스택과 분리한 이유: edge 는 ALB 와 함께 자주 다시 적용되지만 이미지 주소는 늘 떠 있어야 한다.
# ─────────────────────────────────────────────────────────────

data "aws_route53_zone" "this" {
  count = local.use_domain ? 1 : 0

  name         = var.route53_zone_name
  private_zone = false
}

locals {
  upload_bucket              = data.terraform_remote_state.s3.outputs.upload_bucket
  cloudfront_certificate_arn = data.terraform_remote_state.acm.outputs.cloudfront_certificate_arn
  use_domain                 = var.domain_name != ""
}

resource "aws_cloudfront_origin_access_control" "upload" {
  name                              = "${local.name_prefix}-upload"
  description                       = "OAC for upload bucket (image CDN)"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 브라우저가 Content-Type 을 추측해 사진을 다른 형식(HTML · 스크립트)으로 해석하지 않게 nosniff 를 붙인다.
# 버킷 객체는 catalog 가 올릴 때 형식에 맞는 Content-Type 을 적는다
resource "aws_cloudfront_response_headers_policy" "images" {
  name    = "${local.name_prefix}-images"
  comment = "Uploaded images: X-Content-Type-Options nosniff"

  security_headers_config {
    content_type_options {
      override = true
    }
  }
}

# 쿼리 · 쿠키 · 헤더를 캐시 키에 넣지 않는다 (같은 이미지는 하나만 캐시)
resource "aws_cloudfront_cache_policy" "images" {
  name        = "${local.name_prefix}-images"
  comment     = "Uploaded images: long TTL, no query/cookie/header in cache key"
  default_ttl = var.cache_ttl_seconds
  max_ttl     = 31536000
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${local.name_prefix} images"
  price_class     = var.price_class
  aliases         = local.use_domain ? [var.domain_name] : []
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id                = "upload"
    domain_name              = local.upload_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.upload.id
  }

  default_cache_behavior {
    target_origin_id           = "upload"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"] # 조회 전용. 업로드는 catalog 가 버킷에 한다
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.images.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.images.id
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

  tags = { Name = "${local.name_prefix}-images" }

  lifecycle {
    # 인증서가 없으면 도메인 없이 조용히 만들어지므로 막는다
    precondition {
      condition     = !local.use_domain || local.cloudfront_certificate_arn != ""
      error_message = "domain_name ${var.domain_name} 을 쓰려면 acm 스택의 CloudFront 인증서가 있어야 합니다. acm 스택의 subject_alternative_names 에 이 도메인을 넣고 먼저 apply 하세요."
    }
  }
}

# 업로드 버킷은 이 배포의 읽기만 허용한다 (올리기 · 지우기는 서비스 태스크 역할 — iam 스택)
data "aws_iam_policy_document" "upload" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.upload_bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.upload_bucket.arn, "${local.upload_bucket.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "upload" {
  bucket = local.upload_bucket.id
  policy = data.aws_iam_policy_document.upload.json
}

resource "aws_route53_record" "this" {
  for_each = local.use_domain ? toset(["A", "AAAA"]) : toset([])

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
