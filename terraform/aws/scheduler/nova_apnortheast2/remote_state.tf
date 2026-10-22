data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

data "terraform_remote_state" "ecs" {
  backend = "s3"
  config  = local.remote_state.ecs
}

data "terraform_remote_state" "iam" {
  backend = "s3"
  config  = local.remote_state.iam
}

data "terraform_remote_state" "sqs" {
  backend = "s3"
  config  = local.remote_state.sqs
}
