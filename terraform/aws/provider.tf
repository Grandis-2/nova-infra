# 모든 AWS 스택이 공유하는 provider (각 스택 디렉터리에 심볼릭 링크)
#
# assume_role_arn 이 비어 있으면 assume_role 을 건너뛴다.
#   - 로컬: AWS_PROFILE 의 읽기 전용 자격증명을 그대로 쓴다
#   - Atlantis: TF_VAR_assume_role_arn 으로 쓰기 역할(nova-terraform)을 받는다
provider "aws" {
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == "" ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = var.terraform_actor
    }
  }

  default_tags {
    tags = {
      Product   = var.product
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
