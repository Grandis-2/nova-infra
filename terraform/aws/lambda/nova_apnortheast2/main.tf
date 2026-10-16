# Lambda 함수들. 함수마다 <함수>.tf 하나, 코드는 저장소 루트의 functions/<함수>/. 구조와 운영은 ../README.md

locals {
  functions_root = "${path.module}/../../../../functions"
  alerts_topic   = data.aws_sns_topic.alerts.arn
  app_subnet_ids = data.terraform_remote_state.vpc.outputs.app_subnet_ids
  log_bucket     = data.terraform_remote_state.s3.outputs.log_bucket
}
