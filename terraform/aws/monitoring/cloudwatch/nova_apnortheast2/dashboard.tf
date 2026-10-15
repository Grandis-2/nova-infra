# 장애 때 가장 먼저 보는 화면. 위에서부터 사용자 → 앱 → 데이터 순이다.
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "요청 수 · 오류 (ALB)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "응답 시간 (p50 · p95 · p99)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }],
          ]
          annotations = {
            horizontal = [{ label = "목표 500ms", value = 0.5 }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          # AWS/ECS 의 무료 태스크 수 지표(Container Insights 를 쓰지 않는다)
          title  = "서비스별 실행 태스크 수"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            for name in values(local.service_names) :
            ["AWS/ECS", "LiveTaskCount", "ClusterName", local.cluster_name, "ServiceName", name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "서비스별 CPU 사용률"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            for name in values(local.service_names) :
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.cluster_name, "ServiceName", name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "큐 적체 · DLQ"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = concat(
            [for k, q in local.queues : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q.name]],
            [for k, q in local.queues : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q.dlq_name]],
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Valkey CPU · 메모리 (%)"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = concat(
            [for n in local.valkey_nodes : ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", n]],
            [for n in local.valkey_nodes : ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", n]],
          )
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "CloudFront 요청 수 · 5xx 비율"
          region = "us-east-1" # CloudFront 지표는 us-east-1 에만 있다
          view   = "timeSeries"
          period = 300
          metrics = concat(
            [for k, id in local.distributions : ["AWS/CloudFront", "Requests", "DistributionId", id, "Region", "Global", { stat = "Sum", label = "${k} requests" }]],
            [for k, id in local.distributions : ["AWS/CloudFront", "5xxErrorRate", "DistributionId", id, "Region", "Global", { stat = "Average", label = "${k} 5xx %", yAxis = "right" }]],
          )
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "WAF 허용 · 차단 (CloudFront)"
          region = "us-east-1"
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", local.waf_cloudfront, "Rule", "ALL"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", local.waf_cloudfront, "Rule", "ALL"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", local.waf_cloudfront, "Rule", "ApiRateLimit"],
          ]
        }
      },
    ]
  })
}
