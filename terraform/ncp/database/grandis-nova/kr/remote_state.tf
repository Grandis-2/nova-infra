# 허용 IP 로 쓸 AWS NAT 고정 IP
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}
