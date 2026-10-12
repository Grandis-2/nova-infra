variable "slack_team_id" {
  description = "경보를 받을 Slack 워크스페이스 ID (T…). Chatbot 콘솔에서 워크스페이스를 연결해야 생긴다"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "경보를 받을 Slack 채널 ID (C…). 비공개 채널이면 Amazon Q 앱을 초대해야 한다"
  type        = string
  default     = ""
}

variable "alb_5xx_threshold" {
  description = "5분 동안 ALB 가 돌려준 5xx 개수 임계치"
  type        = number
  default     = 20
}

variable "latency_p95_threshold" {
  description = "응답 시간 p95 임계치(초). 목표는 500ms"
  type        = number
  default     = 0.5
}

variable "queue_age_threshold_seconds" {
  description = "가장 오래된 메시지가 이 시간 넘게 대기하면 경보"
  type        = number
  default     = 300
}

variable "cloudfront_5xx_rate_threshold" {
  description = "CloudFront 5xx 비율(%) 임계치. 5분 평균이 두 번 연속 넘으면 경보"
  type        = number
  default     = 5
}

variable "waf_blocked_threshold" {
  description = "CloudFront WAF 가 5분 동안 차단한 요청 수 임계치 (모든 규칙)"
  type        = number
  default     = 500
}

variable "waf_rate_limit_blocked_threshold" {
  description = "IP 요청 수 제한(ApiRateLimit)으로 5분 동안 차단한 요청 수 임계치"
  type        = number
  default     = 100
}
