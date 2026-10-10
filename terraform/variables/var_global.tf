# 모든 스택이 공유하는 변수 (각 스택 디렉터리에 심볼릭 링크)
# 값은 global.auto.tfvars 에 둔다. 실행 주체(assume_role_arn, terraform_actor)만 TF_VAR_* 로 받는다.

variable "product" {
  description = "제품 이름. 리소스 이름 접두사로 쓴다 (예: nova)"
  type        = string
  default     = "nova"
}

variable "env" {
  description = "환경 이름 (예: prod, stage)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "기본 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "availability_zones" {
  description = "사용할 가용영역 2개 (a, c 순서)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "assume_role_arn" {
  description = "Terraform 이 assume 할 역할 ARN. 비우면 assume 하지 않는다"
  type        = string
  default     = ""
}

variable "terraform_actor" {
  description = "assume_role 세션 이름 (Atlantis 사용자명 등)"
  type        = string
  default     = "terraform"
}

variable "tfstate_bucket" {
  description = "원격 상태 S3 버킷. terraform_remote_state 조회에 쓴다"
  type        = string
}

variable "application_dir" {
  description = "서비스 정의 폴더(terraform/application). 비우면 스택 경로를 기준으로 찾는다. 저장소 밖에서 실행할 때만 지정한다"
  type        = string
  default     = ""
}
