variable "engine_version" {
  description = "MySQL 엔진 버전. NCP 와 같은 8.4.11 에서 옮긴다 (aws rds describe-db-engine-versions --engine mysql)"
  type        = string
  default     = "8.4.11"
}

variable "instance_class" {
  description = "인스턴스 클래스 (vCPU 2 · 메모리 8GiB, NCP 와 같은 사양)"
  type        = string
  default     = "db.t4g.large"
}

variable "allocated_storage" {
  description = "처음 스토리지(GiB, gp3). 데이터는 3MiB 안팎이라 최소값으로 둔다"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "스토리지 자동 확장 상한(GiB)"
  type        = number
  default     = 100
}

variable "backup_retention_days" {
  description = "자동 백업 보관(일). NCP 를 내린 뒤의 안전망이다. 0 과 0 이 아닌 값 사이로 바꾸면 재부팅된다"
  type        = number
  default     = 7
}

variable "max_connections" {
  description = <<-EOT
    최대 연결 수. 앱 풀 합계(서비스 최대 태스크 × Hikari 풀, 2026-10-20 기준 약 380, Blue/Green 배포 중 +50)와
    ProxySQL 두 대의 서버별 상한(500 × 2) 중 큰 쪽에 운영 연결 여유를 더했다
  EOT
  type        = number
  default     = 1200
}

variable "long_query_time" {
  description = "slowquery 로그에 남길 최소 실행 시간(초)"
  type        = number
  default     = 1
}

variable "log_bin_trust_function_creators" {
  description = <<-EOT
    SUPER 없는 계정(nova_migrator)이 binlog 가 켜진 DB 에 함수 · 프로시저 · 트리거를 만들 수 있게 한다.
    지금 마이그레이션에는 루틴 · 트리거가 없어 끈다. 생기면 켠다
  EOT
  type        = bool
  default     = false
}

variable "cloudwatch_logs_exports" {
  description = "CloudWatch Logs 로 보낼 로그"
  type        = list(string)
  default     = ["error", "slowquery"]
}

variable "log_retention_days" {
  description = "RDS 로그 보관(일)"
  type        = number
  default     = 14
}

# ── 이전 단계 (terraform.tfvars 에서 단계마다 바꾼다) ──────
variable "replication_filter" {
  description = "replicate-wild-do-table(shop · external_mock 만 복제)을 둔다. 복제하는 동안 true, 전환 뒤 반영 PR 에서 false"
  type        = bool
  default     = true
}

variable "read_only" {
  description = "read_only. 적재 · 계정 생성 때 false, 복제하는 동안 true, 전환 30분 전 false"
  type        = bool
  default     = false
}

variable "local_infile" {
  description = "local_infile. 덤프 적재(MySQL Shell loadDump) 동안만 true"
  type        = bool
  default     = true
}

variable "primary" {
  description = "쓰기 DB. 소비자(ecs 의 마이그레이션 태스크 · 앱 직접 연결, lgtm 의 exporter)가 db_address 로 받는다. 전환 뒤 rds"
  type        = string
  default     = "ncp"

  validation {
    condition     = contains(["ncp", "rds"], var.primary)
    error_message = "primary 는 ncp 또는 rds 다."
  }
}
