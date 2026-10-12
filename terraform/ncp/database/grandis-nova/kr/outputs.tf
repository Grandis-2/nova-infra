output "db_address" {
  description = "Public 도메인. 콘솔에서 켜기 전에는 빈 문자열"
  value       = local.db_host
}

output "db_port" {
  value = var.port
}

output "app_secret_arns" {
  description = "서비스 키 -> DB 계정 시크릿 ARN"
  value       = { for k, s in aws_secretsmanager_secret.service : k => s.arn }
}

output "ops_secret_arns" {
  description = "migrator, admin 시크릿 ARN (운영자, 마이그레이션 전용)"
  value       = { for k, s in aws_secretsmanager_secret.ops : k => s.arn }
}

output "exporter_username" {
  description = "mysqld_exporter 계정 (READ). 관측 스택이 쓴다"
  value       = "nova_exporter"
}

output "exporter_secret_arn" {
  description = "mysqld_exporter 계정 시크릿 ARN (JSON: username · password · host · port). obs 실행 역할만 읽는다"
  value       = aws_secretsmanager_secret.exporter.arn
}
