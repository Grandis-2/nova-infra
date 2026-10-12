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

# mysqld_exporter 가 붙을 NCP DB 주소
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = local.remote_state.database
}
