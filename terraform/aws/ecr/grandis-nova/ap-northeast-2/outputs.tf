output "repository_urls" {
  description = "저장소 키(서비스 키 · migration) -> ECR 저장소 URL"
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_names" {
  description = "저장소 키(서비스 키 · migration) -> ECR 저장소 이름 (<네임스페이스>/<이름>)"
  value       = { for k, r in aws_ecr_repository.this : k => r.name }
}

output "repository_arns" {
  value = { for k, r in aws_ecr_repository.this : k => r.arn }
}
