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
  description = "obs 태스크 메모리(MiB). 컨테이너 한도의 합보다 크고 인스턴스(t4g.large, 8 GiB)가 등록한 메모리보다 작아야 한다"
  type        = number
  default     = 7168
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

variable "obs_mysqld_exporter" {
  description = <<-EOT
    NCP DB 지표(mysqld_exporter). 읽기 전용 exporter 계정(PROCESS, REPLICATION CLIENT, SELECT)과 그 비밀번호 비밀이 생긴 뒤 켠다.
    secret_arn 이 비어 있으면 컨테이너를 만들지 않는다. 비밀은 obs 실행 역할이 읽을 수 있어야 한다(iam 스택).
  EOT
  type = object({
    username   = string
    secret_arn = string
  })
  default = {
    username   = "exporter"
    secret_arn = ""
  }
}

variable "obs_metrics_enabled" {
  description = "지표(Mimir) 컨테이너를 켠다. config/mimir.yaml 과 collector 의 metrics 파이프라인이 들어온 뒤 true (NV-431)"
  type        = bool
  default     = false
}

