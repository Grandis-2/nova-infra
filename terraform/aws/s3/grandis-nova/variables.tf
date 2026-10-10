variable "bucket_suffix" {
  description = "버킷 이름 충돌을 피할 접미사. 비우면 계정 ID 를 쓴다"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "ALB, CloudFront 액세스 로그 보관 기간(일)"
  type        = number
  default     = 30
}

variable "upload_cors_origins" {
  description = "upload 버킷에 presigned URL 로 PUT 할 수 있는 오리진 (프런트 주소)"
  type        = list(string)
  default     = ["https://www.grandis-nova.link"]
}
