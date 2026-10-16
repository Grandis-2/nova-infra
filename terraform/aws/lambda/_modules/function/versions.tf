# 코드를 zip 으로 묶는 archive provider 는 이 모듈만 쓴다.
# 공용 version.tf 에 넣으면 모든 스택이 다시 plan 되므로 여기서만 선언하고, 부르는 스택은 이 요구를 물려받는다
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
