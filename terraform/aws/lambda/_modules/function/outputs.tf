output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_name" {
  description = "실행 역할. 함수마다 권한을 더할 때 쓴다"
  value       = aws_iam_role.this.name
}

output "failed_queue_url" {
  description = "재시도까지 실패한 이벤트가 남는 SQS 큐"
  value       = aws_sqs_queue.failed.url
}
