data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

data "terraform_remote_state" "iam" {
  backend = "s3"
  config  = local.remote_state.iam
}

data "terraform_remote_state" "ecr" {
  backend = "s3"
  config  = local.remote_state.ecr
}

# DB 주소 · 계정 비밀. 지금은 NCP 스택이고, RDS 이전 중에는 rds 스택(NCP 출력을 같은 이름으로 내보내고
# primary 로 쓰기 DB 를 고른다)을 읽는다(db_state). rds 는 공용 remote_state_global 에 넣지 않는다 — 넣으면 모든 스택이 다시 plan 된다
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = var.db_state == "rds" ? merge(local.remote_state_defaults, { key = "${var.env}/rds/terraform.tfstate" }) : local.remote_state.database
}

data "terraform_remote_state" "elasticache" {
  backend = "s3"
  config  = local.remote_state.elasticache
}

data "terraform_remote_state" "sqs" {
  backend = "s3"
  config  = local.remote_state.sqs
}

data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

# 업로드 이미지 URL 접두사 (uploads · upload_cleanup 인 서비스의 설정)
data "terraform_remote_state" "cdn" {
  backend = "s3"
  config  = local.remote_state.cdn
}

data "terraform_remote_state" "secrets" {
  backend = "s3"
  config  = local.remote_state.secretsmanager
}

data "terraform_remote_state" "acm" {
  backend = "s3"
  config  = local.remote_state.acm
}
