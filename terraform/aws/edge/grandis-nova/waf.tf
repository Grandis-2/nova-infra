# WAF — CloudFront(글로벌)와 ALB(리전) 두 곳에 같은 관리형 규칙을 건다
locals {
  # 두 WAF 가 같은 규칙을 쓴다
  managed_rule_groups = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
  ]
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
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
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

        scope_down_statement {
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
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ApiRateLimit"
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

resource "aws_wafv2_web_acl" "alb" {
  name  = "${local.name_prefix}-alb"
  scope = "REGIONAL"

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
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-alb"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-alb-waf" }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}
