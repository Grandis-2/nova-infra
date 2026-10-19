variable "results_expiration_days" {
  description = "버킷 results/ 의 보관 기간(일). 시험 결과(plan · summary · 태스크별 k6 요약)다"
  type        = number
  default     = 180
}

variable "image_retention_count" {
  description = "저장소마다 보관할 이미지 수 (ecr 스택과 같다)"
  type        = number
  default     = 15
}

variable "untagged_expire_days" {
  description = "태그 없는 이미지를 지우기까지의 일수 (ecr 스택과 같다)"
  type        = number
  default     = 3
}
