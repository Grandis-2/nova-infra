data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

data "terraform_remote_state" "s3" {
  backend = "s3"
  config  = local.remote_state.s3
}

# 게이트웨이 수집 주소(gateway_ingest_endpoint).
# 이 스택만 읽어서 공용 remote_state_global 에 넣지 않는다(넣으면 모든 스택이 다시 plan 된다)
data "terraform_remote_state" "lgtm" {
  backend = "s3"
  config  = merge(local.remote_state_defaults, { key = "${var.env}/lgtm/terraform.tfstate" })
}

# 경보 토픽은 monitoring/cloudwatch 스택이 만든다 (Chatbot → Slack 이 이미 구독)
data "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}
