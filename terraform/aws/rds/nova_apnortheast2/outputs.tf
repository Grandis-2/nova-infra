# ── 소비자(ecs · lgtm)가 읽는 출력. NCP 스택(ncp-database)과 같은 이름이다 ─────────

output "db_address" {
  description = "DB 주소(RDS 엔드포인트)"
  value       = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "app_secret_arns" {
  description = "서비스 키 -> DB 계정 시크릿 ARN (secrets.tf)"
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "ops_secret_arns" {
  description = "migrator, admin 시크릿 ARN (secrets.tf)"
  value       = { for k, s in aws_secretsmanager_secret.ops : k => s.arn }
}

output "exporter_username" {
  value = "nova_exporter"
}

output "exporter_secret_arn" {
  value = aws_secretsmanager_secret.exporter.arn
}

# ── 그 밖의 출력 ──────────────────────────────────
output "engine_version" {
  description = "RDS 엔진 버전"
  value       = var.engine_version
}



output "rds_address" {
  description = "RDS 엔드포인트"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "rds_instance_id" {
  description = "DBInstanceIdentifier. monitoring 스택 rds_instance_ids 에 넣는다"
  value       = aws_db_instance.this.identifier
}

output "rds_master_secret_arn" {
  description = "RDS 가 관리하는 마스터 계정(nova_master) 시크릿"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}


