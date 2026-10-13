# WAF — CloudFront(글로벌)에만 건다.
# ALB 는 CloudFront 대역 · 비밀 헤더 요청만 받으므로 ALB 에 다시 걸면 같은 요청을 두 번 검사하고 오탐도 두 번 난다
locals {
  managed_rule_groups = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
  ]

  # 그룹 안에서 차단 대신 표시(label)만 하는 규칙. 우리 API 는 받은 URL 로 서버가 요청하지 않는다.
  #   EC2MetaDataSSRF_BODY   카카오 콜백 본문의 redirectUri(로컬 개발이면 http://localhost:5173/…)가 걸린다.
  #                          아래 SsrfBodyExceptKakaoCallback 이 그 경로만 빼고 다시 막는다
  #   EC2MetaDataSSRF_COOKIE 프런트(Auth.js) 쿠키에 URL 이 담겨 걸린다. API 는 쿠키 값을 URL 로 쓰지 않아 표시만 남긴다
  managed_rule_overrides = {
    AWSManagedRulesCommonRuleSet = ["EC2MetaDataSSRF_BODY", "EC2MetaDataSSRF_COOKIE"]
  }
  ssrf_body_label   = "awswaf:managed:aws:core-rule-set:EC2MetaDataSSRF_Body"
  ssrf_allowed_path = "/api/v1/auth/kakao/callback"

  # 대기열(줄 서기 POST · 조회 GET). 오픈 때 줄 서기가 한꺼번에 몰리고 대기자는 2~4초마다 조회하므로
  # 같은 공인 IP(회사 · 학교 · 통신사 NAT) 뒤에 여럿이면 ApiRateLimit 에 닿는다. 이 경로는 그 규칙에서 빼고 QueueRateLimit 으로 따로 센다
  queue_path = "/api/v1/preorders/queue"
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name  = "${local.name_prefix}-cloudfront"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

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

          dynamic "rule_action_override" {
            for_each = lookup(local.managed_rule_overrides, rule.value.name, [])
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  # 위에서 표시만 한 본문 SSRF 를 카카오 콜백 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다)
  rule {
    name     = "SsrfBodyExceptKakaoCallback"
    priority = 15

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
          label_match_statement {
            scope = "LABEL"
            key   = local.ssrf_body_label
          }
        }

        statement {
          not_statement {
            statement {
              byte_match_statement {
                positional_constraint = "EXACTLY"
                search_string         = local.ssrf_allowed_path

                field_to_match {
                  uri_path {}
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
      metric_name                = "SsrfBodyExceptKakaoCallback"
      sampled_requests_enabled   = true
    }
  }

  # 한 IP 의 과도한 요청을 잠시 막는다. 대기열을 우회하려는 스크립트 요청을 줄인다.
  rule {
    name     = "ApiRateLimit"
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
        limit              = var.api_rate_limit_per_5min
        aggregate_key_type = "IP"

        # /api/ 아래에서 대기열 경로만 뺀다
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = "/api/"

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
              not_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "STARTS_WITH"
                    search_string         = local.queue_path

                    field_to_match {
                      uri_path {}
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
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ApiRateLimit"
      sampled_requests_enabled   = true
    }
  }

  # 대기열 전용 한도(줄 서기 · 조회). 앱이 회원별 조회 간격(Retry-After)을 정하므로 여기서는 NAT 뒤 다수를 막지 않을 만큼 넉넉히 둔다.
  # 산정: 대기자 한 명이 5분에 약 100건(2~4초 간격 조회) + 오픈 때 줄 서기. 통신사 CGNAT 은 공인 IP 하나 뒤에
  #       수천 명이 있을 수 있어 약 3,000명분(300,000)으로 잡았다. 한 IP 의 과다 요청은 WAF 가 아니라
  #       앱(인증 · Retry-After)이 맡는다. 줄이려면 queue_rate_limit_per_5min 만 바꾼다
  rule {
    name     = "QueueRateLimit"
    priority = 110

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
        limit              = var.queue_rate_limit_per_5min
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = local.queue_path

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "QueueRateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-cloudfront-waf" }
}
