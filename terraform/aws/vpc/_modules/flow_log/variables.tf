variable "name_prefix" {
  description = "리소스 이름 접두사 (예: nova-prod)"
  type        = string
}

variable "vpc_id" {
  description = "Flow Log 를 켤 VPC"
  type        = string
}

variable "traffic_type" {
  description = "기록할 트래픽. 비용을 줄이려고 기본은 차단된 트래픽만"
  type        = string
  default     = "REJECT"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.traffic_type)
    error_message = "traffic_type 은 ACCEPT | REJECT | ALL 중 하나여야 합니다."
  }
}

variable "retention_in_days" {
  description = "로그 보관 기간(일)"
  type        = number
  default     = 14
}
