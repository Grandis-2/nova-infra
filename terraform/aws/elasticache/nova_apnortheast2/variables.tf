variable "engine_version" {
  description = "Valkey 엔진 버전 (aws elasticache describe-cache-engine-versions --engine valkey)"
  type        = string
  default     = "9.1"
}

variable "node_type" {
  description = "노드 타입"
  type        = string
  default     = "cache.t4g.small"
}

variable "multi_az" {
  description = "다른 AZ 에 복제본을 두고 자동 장애조치를 켠다. 끄면 노드 1개"
  type        = bool
  default     = false
}

variable "snapshot_retention_days" {
  description = "스냅샷 보관 기간(일). 0 이면 스냅샷을 끈다"
  type        = number
  default     = 1
}

