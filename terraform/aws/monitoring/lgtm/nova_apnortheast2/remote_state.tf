data "terraform_remote_state" "ecs" {
  backend = "s3"
  config  = local.remote_state.ecs
}

data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

data "terraform_remote_state" "iam" {
  backend = "s3"
  config  = local.remote_state.iam
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

data "terraform_remote_state" "secretsmanager" {
  backend = "s3"
  config  = local.remote_state.secretsmanager
}

# mysqld_exporter 가 붙을 DB 의 주소 · 계정 · 비밀(db_address · db_port · exporter_username · exporter_secret_arn).
# RDS 이전 중에는 rds 스택(같은 이름의 출력, db_address 는 primary 의 주소)을 읽는다(db_state)
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = var.db_state == "rds" ? merge(local.remote_state_defaults, { key = "${var.env}/rds/terraform.tfstate" }) : local.remote_state.database
}

# Grafana 공개 (NV-517) — 인증서 이름 · ARN
data "terraform_remote_state" "acm" {
  backend = "s3"
  config  = local.remote_state.acm
}

# Grafana 공개 (NV-517) — Cognito 풀 · 클라이언트.
# 이 스택만 읽어서 공용 remote_state_global 에 넣지 않는다(넣으면 모든 스택이 다시 plan 된다)
data "terraform_remote_state" "cognito" {
  backend = "s3"
  config  = merge(local.remote_state_defaults, { key = "${var.env}/cognito/terraform.tfstate" })
}

# OTel 게이트웨이(NV-543)를 앱 서브넷에 띄운다
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}
