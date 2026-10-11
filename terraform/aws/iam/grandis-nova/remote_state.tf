data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

data "terraform_remote_state" "sqs" {
  backend = "s3"
  config  = local.remote_state.sqs
}

data "terraform_remote_state" "ecr" {
  backend = "s3"
  config  = local.remote_state.ecr
}
