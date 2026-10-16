# ─────────────────────────────────────────────────────────────
# 브라우저 실사용자 모니터링 수집 주소 — rum.<도메인> → 이 CloudFront(전용 WAF) → ALB → 브라우저 수집기
#
# 프런트(Grafana Faro SDK)가 브라우저에서 바로 POST /collect 로 보낸다. Vercel 을 거치지 않아 WAF 가 실제 사용자 IP 로 센다.
# API 배포와 따로 두는 이유:
#   - API 의 관리형 규칙(CommonRuleSet)은 오류 스택 · HTML 조각이 든 본문을 공격으로 오인하고, 본문 8KB 상한에도 걸린다
#   - 누구나 보낼 수 있는 공개 수집 경로라 규칙(경로 · 메서드 · 크기 · 비율)을 이 용도에 맞게 좁힌다
#   - 수집 쪽을 끄거나 바꿔도 API 에 영향이 없다
# Grafana 배포와 같이 Host 를 그대로 넘긴다. ALB 는 rum 인증서(monitoring/lgtm 스택이 SNI 로 붙임)를 내주고,
# Host · 원본 확인 헤더 · 경로로 수집기 대상 그룹에 보낸다. CORS(허용 출처)는 수집기가 답한다.
# ─────────────────────────────────────────────────────────────

locals {
  rum_domain  = try(data.terraform_remote_state.acm.outputs.rum_domain_name, "")
  rum_enabled = local.rum_domain != "" && local.origin_over_https

  rum_collect_path = "/collect"

  # Content-Length 0 ~ 249,999. Faro 는 한 번에 최대 50건을 압축 없이 보내 오류 스택이 많으면 수십 KB 가 된다
  # WAF 는 본문 앞 16KB 만 보므로 헤더로 판단한다. 헤더가 없으면(chunked) 막힌다
  rum_content_length_regex = "^([0-9]{1,5}|1[0-9]{5}|2[0-4][0-9]{4})$"

  rum_managed_rule_groups = [
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
  ]
}

resource "aws_wafv2_web_acl" "rum" {
  provider = aws.us_east_1
  count    = local.rum_enabled ? 1 : 0

  name  = "${local.name_prefix}-rum"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # POST /collect 와 그 사전 요청(OPTIONS)만 받는다
  rule {
    name     = "CollectOnly"
    priority = 0

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      not_statement {
        statement {
          and_statement {
            statement {
              byte_match_statement {
                positional_constraint = "EXACTLY"
                search_string         = local.rum_collect_path

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              regex_match_statement {
                regex_string = "^(POST|OPTIONS)$"

                field_to_match {
                  method {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RumCollectOnly"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "CollectBodySize"
    priority = 10

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            positional_constraint = "EXACTLY"
            search_string         = "POST"

            field_to_match {
              method {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = local.rum_content_length_regex

                field_to_match {
                  single_header {
                    name = "content-length"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RumCollectBodySize"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.rum_managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = var.waf_block_mode ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = var.waf_block_mode ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "Rum${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "RumRateLimit"
    priority = 100

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.rum_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RumRateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-rum"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-rum-waf" }
}

resource "aws_cloudfront_distribution" "rum" {
  count = local.rum_enabled ? 1 : 0

  enabled         = true
  comment         = "${local.name_prefix} rum"
  price_class     = var.price_class
  aliases         = [local.rum_domain]
  web_acl_id      = aws_wafv2_web_acl.rum[0].arn
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
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "https-only" # SDK 가 https 주소로만 보낸다
    # POST 를 받으려면 7개 묶음을 골라야 한다. POST · OPTIONS 외에는 WAF 가 막는다
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

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
    acm_certificate_arn      = data.terraform_remote_state.acm.outputs.rum_cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = "${local.log_bucket.id}.s3.amazonaws.com"
    prefix          = "cloudfront-rum/"
    include_cookies = false
  }

  tags = { Name = "${local.name_prefix}-rum" }
}

resource "aws_route53_record" "rum" {
  for_each = local.rum_enabled ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.route53_zone_id
  name    = local.rum_domain
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.rum[0].domain_name
    zone_id                = aws_cloudfront_distribution.rum[0].hosted_zone_id
    evaluate_target_health = false
  }
}
