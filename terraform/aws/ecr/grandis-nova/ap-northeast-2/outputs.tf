output "repository_urls" {
  description = "서비스 키 -> ECR 저장소 URL"
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_names" {
  description = "서비스 키 -> ECR 저장소 이름 (<네임스페이스>/<서비스>)"
  value       = { for k, r in aws_ecr_repository.this : k => r.name }
}

output "repository_arns" {
  value = { for k, r in aws_ecr_repository.this : k => r.arn }
}
