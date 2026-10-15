# 트래픽이 없어도 알아야 하는 엣지 문제(NV-541). 공개 URL 을 직접 찔러 보는 대신 AWS 가 이미 내는 지표로 본다.
#
#   인증서 만료   ACM DaysToExpiry. ALB 인증서는 서울, CloudFront 인증서는 us-east-1 에 지표가 있다.
#                 ACM 이 만료 60일 전부터 자동 갱신하므로, 14일 남았다는 것은 갱신(DNS 검증 레코드 등)이 막혔다는 뜻이다.
#   ALB 4xx 비율  ALB 가 직접 만든 4xx(대상에 넘기지 않은 요청) / 전체 요청. 원본 확인 헤더나 리스너 규칙이 어긋나면
#                 모든 요청이 ALB 기본 404 로 끝나는데, 5xx 가 아니라 다른 경보가 울리지 않는다.
#                 요청이 5분 20건 미만이면 비율을 보지 않는다(몇 건의 스캐너 요청으로 튀지 않게).
locals {
  acm = data.terraform_remote_state.acm.outputs
  certs_seoul = { for k, arn in {
    api_alb     = local.acm.alb_certificate_arn
    grafana_alb = local.acm.grafana_alb_certificate_arn
  } : k => arn if arn != "" }
  certs_us_east_1 = { for k, arn in {
    api_cloudfront     = local.acm.cloudfront_certificate_arn
    grafana_cloudfront = local.acm.grafana_cloudfront_certificate_arn
  } : k => arn if arn != "" }
}

resource "aws_cloudwatch_metric_alarm" "cert_expiry" {
  for_each = local.certs_seoul

  alarm_name          = "${local.name_prefix}-cert-expiry-${each.key}"
  alarm_description   = "ACM certificate ${each.key} expires in under ${var.cert_expiry_days} days. Auto renewal is blocked (check DNS validation records)"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.cert_expiry_days
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { CertificateArn = each.value }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "cert_expiry_us_east_1" {
  for_each = local.certs_us_east_1
  provider = aws.us_east_1

  alarm_name          = "${local.name_prefix}-cert-expiry-${each.key}"
  alarm_description   = "ACM certificate ${each.key} expires in under ${var.cert_expiry_days} days. Auto renewal is blocked (check DNS validation records)"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.cert_expiry_days
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { CertificateArn = each.value }

  alarm_actions = [aws_sns_topic.alerts_us_east_1.arn]
  ok_actions    = [aws_sns_topic.alerts_us_east_1.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_elb_4xx_ratio" {
  alarm_name          = "${local.name_prefix}-alb-elb-4xx-ratio"
  alarm_description   = "Most requests end in ALB-generated 4xx (default 404 or blocked path). Origin verify header or listener rules may be broken"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.alb_elb_4xx_ratio_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "IF(requests >= 20, elb4xx / requests, 0)"
    label       = "ALB-generated 4xx ratio"
    return_data = true
  }

  metric_query {
    id = "elb4xx"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_4XX_Count"
      dimensions  = { LoadBalancer = local.alb_suffix }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = local.alb_suffix }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
