# ── NCP 스택(ncp-database)과 같은 이름의 출력 ─────────────────
# 소비자는 database 원격 상태의 key 만 이 스택(prod/rds)으로 바꾸면 된다.
# 시크릿은 아직 NCP 스택이 만든 것이다(앱 계정은 RDS 에도 같은 이름 · 비밀번호로 만든다). 이전이 끝나면 이 스택으로 소유권을 옮긴다

output "db_address" {
  description = "쓰기 DB 주소. primary 가 ncp 면 NCP Public 도메인, rds 면 RDS 엔드포인트"
  value       = var.primary == "rds" ? aws_db_instance.this.address : local.ncp.db_address
}

output "db_port" {
  value = var.primary == "rds" ? aws_db_instance.this.port : local.ncp.db_port
}

output "app_secret_arns" {
  description = "서비스 키 -> DB 계정 시크릿 ARN (NCP 스택 출력 그대로)"
  value       = local.ncp.app_secret_arns
}

output "ops_secret_arns" {
  description = "migrator, admin 시크릿 ARN (NCP 스택 출력 그대로)"
  value       = local.ncp.ops_secret_arns
}

output "exporter_username" {
  value = local.ncp.exporter_username
}

output "exporter_secret_arn" {
  value = local.ncp.exporter_secret_arn
}

# ── 이전 기간에만 쓰는 출력 ──────────────────────────────────
output "engine_version" {
  description = "RDS 엔진 버전. ProxySQL 이 앱에 알리는 server_version 과 맞춘다"
  value       = var.engine_version
}

output "primary" {
  value = var.primary
}

output "ncp_address" {
  description = "NCP Public 도메인. ProxySQL 의 ncp 서버 · 런북의 복제 소스"
  value       = local.ncp.db_address
}

output "rds_address" {
  description = "RDS 엔드포인트. ProxySQL 의 rds 서버 · 런북의 대상"
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
  description = "RDS 가 관리하는 마스터 계정(nova_master) 시크릿. 런북만 읽는다"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "writer_parameter" {
  description = "현재 쓰기 대상(ncp | rds) SSM 파라미터. ProxySQL 이 시작할 때 읽고 런북이 쓴다"
  value = {
    name = aws_ssm_parameter.writer.name
    arn  = aws_ssm_parameter.writer.arn
  }
}

output "dump_coords_parameter" {
  description = "덤프 위치 SSM 파라미터 (런북이 쓴다)"
  value = {
    name = aws_ssm_parameter.dump_coords.name
    arn  = aws_ssm_parameter.dump_coords.arn
  }
}
