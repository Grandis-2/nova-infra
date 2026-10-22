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
  description = "5분 동안 ALB 가 직접 만든 5xx(대상 없음 · 시간 초과) 개수 임계치"
  type        = number
  default     = 20
}

variable "queue_age_threshold_seconds" {
  description = "가장 오래된 메시지가 이 시간 넘게 대기하면 경보"
  type        = number
  default     = 300
}

variable "queue_age_threshold_overrides" {
  description = "큐별 문턱(초). 일부러 지연시켜 다시 보내는 큐는 그 지연보다 길게 둔다"
  type        = map(number)
  default = {
    # worker 는 등록 · 취소가 한 세대(4차례) 내내 실패하면 약 12분(±20%, 최대 14.4분) 뒤 다음 세대로 다시 보낸다.
    # 등록은 3세대, 취소는 8세대 뒤 포기한다(be worker.retry). 지연 중인 메시지도 나이가 쌓일 수 있어 그 간격보다 길게 둔다
    "preorder-register" = 1200
    "preorder-cancel"   = 1200
    # worker 가 지우지 않고 가시성 시간을 늘려 다시 받는다(대기 1m+5m+15m+30m+1h, 합계 약 1시간 51분 뒤 5회 수신으로 DLQ)
    "draw-register" = 7200
    # member 의 관리자 알림 소비자가 나오기 전까지 preorder · order 의 관리자 알림이 쌓이기만 한다. 보관 기간(4일)과 같게 두어 울리지 않게 하고,
    # 소비자가 배포되면 이 줄을 지운다
    "admin-alert" = 345600
  }

  validation {
    condition     = alltrue([for v in values(var.queue_age_threshold_overrides) : v > 0])
    error_message = "queue_age_threshold_overrides 값은 0 보다 커야 한다 (초)."
  }
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

variable "rds_instance_ids" {
  description = "경보를 걸 RDS 인스턴스 식별자(DBInstanceIdentifier). 비어 있으면 RDS 경보를 만들지 않는다"
  type        = list(string)
  default     = []
}

variable "rds_free_storage_threshold_gib" {
  description = "RDS 남은 스토리지 경보 문턱(GiB)"
  type        = number
  default     = 10
}

variable "cloudfront_additional_metrics" {
  description = "추가 지표를 켤 CloudFront 배포(edge.tf 의 local.distributions 키). 배포마다 월 과금이 붙는다"
  type        = list(string)
  default     = ["api", "images"]

  # 오타면 그 배포의 구독이 for_each 에서 빠져 plan 이 지우려 든다. 검증은 locals 를 못 읽으므로 키를 여기 적는다
  validation {
    condition     = alltrue([for k in var.cloudfront_additional_metrics : contains(["api", "images"], k)])
    error_message = "cloudfront_additional_metrics 는 api · images 중에서 고른다(edge.tf 의 local.distributions 키)."
  }
}

variable "cert_expiry_days" {
  description = "인증서 만료 경보 기준(남은 일수). ACM 은 만료 60일 전부터 자동 갱신하므로 이 경보는 갱신이 막힌 것이다"
  type        = number
  default     = 14
}

variable "alb_elb_4xx_ratio_threshold" {
  description = "ALB 가 직접 만든 4xx 의 비율 경보 기준(0~1). 평소에도 스캐너의 없는 경로(기본 404) · 목업 관리 경로 차단(403)이 섞여 1주 재고 조정한다"
  type        = number
  default     = 0.5
}
