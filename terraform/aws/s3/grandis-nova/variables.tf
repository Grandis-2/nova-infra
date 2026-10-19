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

variable "loki_expiration_days" {
  description = "loki 버킷의 객체 만료(일). Loki compactor 가 멈췄을 때를 위한 안전망이라 보존 기간(90일)보다 길게 둔다"
  type        = number
  default     = 100

  validation {
    condition     = var.loki_expiration_days > 90
    error_message = "loki_expiration_days 는 Loki 보존 기간(90일, retention_period 2160h)보다 길어야 합니다. 같거나 짧으면 compactor 보다 먼저 지웁니다."
  }
}

variable "tempo_expiration_days" {
  description = "tempo 버킷의 객체 만료(일). Tempo compactor 가 멈췄을 때를 위한 안전망이라 트레이스 보존 기간(14일)보다 길게 둔다"
  type        = number
  default     = 30

  validation {
    condition     = var.tempo_expiration_days > 14
    error_message = "tempo_expiration_days 는 Tempo 보존 기간(14일, block_retention 336h)보다 길어야 합니다. 같거나 짧으면 compactor 보다 먼저 지웁니다."
  }
}

variable "loadtest_results_expiration_days" {
  description = "loadtest 버킷 results/ 의 보관 기간(일). 시험 결과(plan · summary · 태스크별 k6 요약)다"
  type        = number
  default     = 180
}
