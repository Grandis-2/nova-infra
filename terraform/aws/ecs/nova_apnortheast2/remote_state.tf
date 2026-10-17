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

# DB 는 NCP 에 있다
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = local.remote_state.database
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
