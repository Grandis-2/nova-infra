data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

data "terraform_remote_state" "acm" {
  backend = "s3"
  config  = local.remote_state.acm
}
