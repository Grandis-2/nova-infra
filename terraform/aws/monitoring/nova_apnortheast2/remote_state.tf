data "terraform_remote_state" "ecs" {
  backend = "s3"
  config  = local.remote_state.ecs
}

data "terraform_remote_state" "sqs" {
  backend = "s3"
  config  = local.remote_state.sqs
}

data "terraform_remote_state" "elasticache" {
  backend = "s3"
  config  = local.remote_state.elasticache
}

data "terraform_remote_state" "edge" {
  backend = "s3"
  config  = local.remote_state.edge
}

data "terraform_remote_state" "cdn" {
  backend = "s3"
  config  = local.remote_state.cdn
}
