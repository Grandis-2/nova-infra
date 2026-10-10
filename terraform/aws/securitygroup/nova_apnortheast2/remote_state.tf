data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

locals {
  vpc_id     = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr   = data.terraform_remote_state.vpc.outputs.vpc_cidr
  vpce_sg_id = data.terraform_remote_state.vpc.outputs.vpce_security_group_id
}
