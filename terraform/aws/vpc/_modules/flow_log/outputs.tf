output "flow_log_id" {
  description = "Flow Log ID"
  value       = aws_flow_log.this.id
}

output "log_group_name" {
  description = "Flow Logs 가 기록되는 CloudWatch 로그 그룹"
  value       = aws_cloudwatch_log_group.this.name
}

output "role_arn" {
  description = "Flow Logs 서비스가 맡는 전달 역할"
  value       = aws_iam_role.this.arn
}
