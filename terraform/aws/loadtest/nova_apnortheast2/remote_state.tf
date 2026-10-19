data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

# 게이트웨이 · obs SG (들어오는 규칙을 더한다)
data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

# 헤더 · member 서명키 ARN
data "terraform_remote_state" "secrets" {
  backend = "s3"
  config  = local.remote_state.secretsmanager
}

# 컨트롤러가 정리 전에 보는 큐
data "terraform_remote_state" "sqs" {
  backend = "s3"
  config  = local.remote_state.sqs
}

# 관측 클러스터 이름
data "terraform_remote_state" "ecs" {
  backend = "s3"
  config  = local.remote_state.ecs
}

# 게이트웨이 수집 주소 · obs 서비스 이름.
# lambda 처럼 이 스택만 읽어서 공용 remote_state_global 에 넣지 않는다(넣으면 모든 스택이 다시 plan 된다)
data "terraform_remote_state" "lgtm" {
  backend = "s3"
  config  = merge(local.remote_state_defaults, { key = "${var.env}/lgtm/terraform.tfstate" })
}

# 계정에 이미 있는 GitHub OIDC 공급자 (iam 스택도 조회해서 쓴다)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
