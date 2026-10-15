variable "jobs" {
  description = <<-EOT
    배치 작업 목록.
      schedule : cron 또는 rate 식 (timezone 기준)
      command  : 배치 컨테이너에 넘길 인자. 앱이 이 값으로 작업을 구분한다
      enabled  : false 면 스케줄을 꺼둔다 (리소스는 유지)
  EOT

  type = map(object({
    schedule    = string
    command     = list(string)
    description = string
    enabled     = optional(bool, true)
  }))
}

variable "timezone" {
  description = "스케줄 해석 기준 시간대"
  type        = string
  default     = "Asia/Seoul"
}

variable "retry_attempts" {
  description = "RunTask 호출 실패 시 재시도 횟수. 초과하면 DLQ 로 간다"
  type        = number
  default     = 3
}
