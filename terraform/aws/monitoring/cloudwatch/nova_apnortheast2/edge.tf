# CloudFront · 글로벌 WAF 경보와 CloudFront 추가 지표 구독. 지표가 us-east-1 에만 있어 경보와 토픽도 us-east-1 에 둔다.
locals {
  distributions = {
    api    = data.terraform_remote_state.edge.outputs.cloudfront_distribution_id
    images = data.terraform_remote_state.cdn.outputs.distribution_id
  }

  # Web ACL 이름은 edge 스택(waf.tf)의 이름 규칙을 따른다
  waf_cloudfront = "${local.name_prefix}-cloudfront"
}

resource "aws_sns_topic" "alerts_us_east_1" {
  provider = aws.us_east_1

  name = "${local.name_prefix}-alerts"

  tags = { Name = "${local.name_prefix}-alerts" }
}

data "aws_iam_policy_document" "sns_us_east_1" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts_us_east_1.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts_us_east_1" {
  provider = aws.us_east_1

  arn    = aws_sns_topic.alerts_us_east_1.arn
  policy = data.aws_iam_policy_document.sns_us_east_1.json
}

# 사용자가 받은 응답 중 5xx 비율. ALB 경보와 달리 CloudFront 자체 오류(원본 연결 실패 등)도 잡는다
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  provider = aws.us_east_1
  for_each = local.distributions

  alarm_name          = "${local.name_prefix}-cloudfront-${each.key}-5xx"
  alarm_description   = "CloudFront (${each.key}) 5xx error rate is above ${var.cloudfront_5xx_rate_threshold}%"
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.cloudfront_5xx_rate_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = each.value
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.alerts_us_east_1.arn]
  ok_actions    = [aws_sns_topic.alerts_us_east_1.arn]
}

# 차단이 급증하면 공격이나 스크립트 요청이다. 정상 사용자가 막히는 오탐인지도 이걸로 안다
resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  provider = aws.us_east_1
  for_each = {
    all              = { rule = "ALL", threshold = var.waf_blocked_threshold }
    rate-limit       = { rule = "ApiRateLimit", threshold = var.waf_rate_limit_blocked_threshold }
    queue-rate-limit = { rule = "QueueRateLimit", threshold = var.waf_rate_limit_blocked_threshold }
  }

  alarm_name          = "${local.name_prefix}-waf-cloudfront-${each.key}"
  alarm_description   = "WAF (CloudFront) blocked more than ${each.value.threshold} requests in 5 minutes (rule ${each.value.rule})"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = local.waf_cloudfront
    Rule   = each.value.rule
  }

  alarm_actions = [aws_sns_topic.alerts_us_east_1.arn]
}

# CloudFront 추가 지표: 캐시 적중률 · 오리진 지연 · 오류 코드별(401 · 403 · 404 · 502 · 503 · 504) 비율.
# 기본 지표(요청 · 바이트 · 4xx/5xx 비율)에 없는 것들이다. 배포마다 CloudWatch 사용자 지정 지표 8개 값이 과금된다
resource "aws_cloudfront_monitoring_subscription" "this" {
  provider = aws.us_east_1
  for_each = { for k, v in local.distributions : k => v if contains(var.cloudfront_additional_metrics, k) }

  distribution_id = each.value

  monitoring_subscription {
    realtime_metrics_subscription_config {
      realtime_metrics_subscription_status = "Enabled"
    }
  }
}

# 키 오타는 구독이 조용히 빠지고 추가 지표 패널만 비므로 알린다
check "cloudfront_additional_metrics_keys" {
  assert {
    condition     = length(setsubtract(var.cloudfront_additional_metrics, keys(local.distributions))) == 0
    error_message = "cloudfront_additional_metrics 에 없는 배포가 있다: ${join(", ", setsubtract(var.cloudfront_additional_metrics, keys(local.distributions)))}. 쓸 수 있는 키: ${join(", ", keys(local.distributions))}"
  }
}
