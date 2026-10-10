# CloudFront 인증서와 CLOUDFRONT 범위 WAF 는 us-east-1 에만 만들 수 있다.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

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
