output "app_secret_arns" {
  description = "서비스 키 -> 시크릿 ARN (secrets.sops.yml 이 있는 서비스만)"
  value       = { for k, s in aws_secretsmanager_secret.service : k => s.arn }
}

output "app_secret_keys" {
  description = "서비스 키 -> 시크릿 안의 키(= 환경변수) 이름"
  value       = local.secret_keys
}

output "generated_secret_arns" {
  description = "\"<서비스>/<환경변수>\" -> 생성 비밀 ARN (값 전체가 그 환경변수 값)"
  value       = { for id, s in aws_secretsmanager_secret.generated : id => s.arn }
}

output "shared_secret_arns" {
  description = "공유 비밀 이름 -> ARN"
  value       = { for n, s in aws_secretsmanager_secret.shared : n => s.arn }
}

output "ops_secret_names" {
  description = "사람이 조회하는 운영 비밀 (관리자 세션: aws secretsmanager get-secret-value --secret-id <이름>)"
  value       = concat([for s in aws_secretsmanager_secret.admin_password : s.name], [aws_secretsmanager_secret.grafana_admin.name])
}

output "grafana_admin_secret_arn" {
  description = "관측 호스트(obs) Grafana admin 비밀번호. obs 역할만 읽는다 (실행 역할은 ops/* 를 읽지 못한다)"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "loadtest_header_secret" {
  description = "부하 시험 헤더 값. edge(WAF 규칙)와 부하 시험 실행 역할이 읽는다"
  value = {
    name = aws_secretsmanager_secret.loadtest_header.name
    arn  = aws_secretsmanager_secret.loadtest_header.arn
  }
}
