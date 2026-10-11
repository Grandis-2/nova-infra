data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

data "terraform_remote_state" "ecs" {
  backend = "s3"
  config  = local.remote_state.ecs
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

data "terraform_remote_state" "acm" {
  backend = "s3"
  config  = local.remote_state.acm
}
