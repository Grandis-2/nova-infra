# 다른 스택의 output 을 읽을 때 쓰는 상태 위치
#
#   data "terraform_remote_state" "vpc" {
#     backend = "s3"
#     config  = local.remote_state.vpc
#   }
#
# 키는 스택 이름, 값은 그 스택의 backend 설정이다. key 경로를 바꾸면 기존 상태를 못 찾으니 그대로 둔다.
# assume_role_arn 이 있으면 상태 버킷도 그 역할로 읽는다.
locals {
  remote_state_defaults = merge(
    {
      bucket  = var.tfstate_bucket
      region  = var.aws_region
      encrypt = true
    },
    var.assume_role_arn == "" ? {} : {
      assume_role = { role_arn = var.assume_role_arn }
    },
  )

  remote_state = {
    for name, key in {
      sops           = "sops"        # aws/kms/grandis-nova/ap-northeast-2
      vpc            = "vpc"         # aws/vpc/nova_apnortheast2
      securitygroup  = "security"    # aws/securitygroup/nova_apnortheast2
      s3             = "s3"          # aws/s3/grandis-nova
      sqs            = "sqs"         # aws/sqs/grandis-nova/ap-northeast-2
      ecr            = "ecr"         # aws/ecr/grandis-nova/ap-northeast-2
      acm            = "acm"         # aws/acm/grandis-nova/ap-northeast-2
      secretsmanager = "secrets"     # aws/secretsmanager/grandis-nova/ap-northeast-2
      database       = "database"    # ncp/database/grandis-nova/kr
      elasticache    = "elasticache" # aws/elasticache/nova_apnortheast2
      iam            = "iam"         # aws/iam/grandis-nova
      ecs            = "ecs"         # aws/ecs/nova_apnortheast2
    } : name => merge(local.remote_state_defaults, { key = "${var.env}/${key}/terraform.tfstate" })
  }
}
