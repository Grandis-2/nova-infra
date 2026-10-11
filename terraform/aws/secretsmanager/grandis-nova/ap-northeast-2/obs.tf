# 관측 호스트(obs)의 Grafana admin 비밀번호 (Grandis-2/nova-observability).
# 호스트가 부팅할 때 obs 역할로 읽어 Grafana 에 파일로 넘긴다. 사람은 이 값으로 로그인한다.
# ops/* 라 서비스(실행 역할)는 읽지 못한다.
#
# generated.tf 와 같이 ephemeral 로 만들어 쓰기 전용으로 넣는다. secret_versions["ops/grafana"] 를 올리면 새 값이 된다.
# Grafana 는 처음 뜰 때만 이 값을 admin 에 쓴다. 이미 떠 있는 Grafana 의 비밀번호를 바꾸는 절차는 nova-observability README 에 있다.

locals {
  grafana_admin_version_key = "ops/grafana"
}

ephemeral "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${local.name_prefix}/ops/grafana/admin-password"
  description             = "Grafana admin password for the observability host"
  recovery_window_in_days = 7

  tags = { Service = "obs" }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id                = aws_secretsmanager_secret.grafana_admin.id
  secret_string_wo         = ephemeral.random_password.grafana_admin.result
  secret_string_wo_version = local.version_of[local.grafana_admin_version_key]
}
