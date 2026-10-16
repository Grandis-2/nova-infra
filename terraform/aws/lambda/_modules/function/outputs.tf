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
