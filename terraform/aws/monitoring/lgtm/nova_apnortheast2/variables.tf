variable "obs_retention" {
  description = "관측 스택 보존 기간 (Loki · Tempo · Mimir 형식). 버킷 수명주기 안전망(s3 스택)보다 짧아야 한다"
  type = object({
    logs    = string
    traces  = string
    metrics = string
  })
  default = {
    logs    = "2160h" # 90일. loki 버킷 만료 100일
    traces  = "336h"  # 14일. tempo 버킷 만료 30일
    metrics = "2160h" # 90일. mimir 버킷은 만료 없음(경보 규칙이 같이 있다)
  }
}

variable "obs_task_memory" {
  description = "obs 태스크 메모리(MiB). 컨테이너 한도의 합(7456)보다 크고 인스턴스(t4g.large)가 ECS 에 등록한 메모리(7813)보다 작아야 한다"
  type        = number
  default     = 7680
}

variable "obs_log_retention_days" {
  description = "obs 컨테이너 로그(CloudWatch) 보관 기간(일)"
  type        = number
  default     = 14
}

variable "obs_cpu_credit_threshold" {
  description = "obs 인스턴스 CPU 크레딧 잔량 경보 임계치"
  type        = number
  default     = 20
}

variable "obs_mysqld_exporter_enabled" {
  description = <<-EOT
    DB 지표(mysqld_exporter) 컨테이너. 계정과 비밀은 database 원격 상태의 DB 스택이 만들고,
    obs 실행 역할이 비밀을 읽는다(iam 스택). 끄면 컨테이너를 만들지 않고 Collector 도 긁지 않는다.
  EOT
  type        = bool
  default     = true
}

variable "obs_mysql_platform" {
  description = "mysqld_exporter 가 긁는 DB 의 플랫폼. 켜는 수집기가 달라진다(main.tf 의 obs_mysqld_collectors)"
  type        = string
  default     = "ncp"

  validation {
    condition     = contains(["ncp", "rds"], var.obs_mysql_platform)
    error_message = "obs_mysql_platform 은 ncp 또는 rds 다."
  }
}
