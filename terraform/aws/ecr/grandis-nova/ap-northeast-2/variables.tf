variable "repository_namespace" {
  description = "저장소 네임스페이스. 저장소 이름은 <네임스페이스>/<서비스>. be release.yml 의 ECR_NAMESPACE 와 같아야 한다"
  type        = string
  default     = "nova"
}

variable "image_retention_count" {
  description = "보관할 이미지 수"
  type        = number
  default     = 15
}

variable "untagged_expire_days" {
  description = "태그 없는 이미지를 지우기까지의 일수"
  type        = number
  default     = 3
}

variable "existing_repositories" {
  description = "Terraform 밖에서 이미 만든 저장소. import 블록으로 상태에 가져온다"
  type        = list(string)
  default = [
    "nova/member", "nova/catalog", "nova/preorder", "nova/order",
    "nova/payment", "nova/waitingroom", "nova/worker", "nova/batch",
  ]
}
