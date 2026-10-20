data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

# NCP DB 스택. 출력 6개를 같은 이름으로 다시 내보낸다(outputs.tf)
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = local.remote_state.database
}
