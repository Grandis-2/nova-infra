output "alerts_topic_arn" {
  description = "Slack(Chatbot) 등 추가 구독을 붙일 토픽"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}
