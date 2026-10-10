variable "vpc_cidr" {
  description = "NCP VPC 대역. AWS VPC(10.0.0.0/16)와 겹치면 안 된다"
  type        = string
  default     = "10.100.0.0/16"
}

variable "zone" {
  description = "NCP 존 (KR-1, KR-2)"
  type        = string
  default     = "KR-2"
}

# 서버 사양 — 세대 · 타입 · vCPU · 메모리로 NCP 사양 목록에서 고른다 (사양 코드를 손으로 적지 않는다)
# max_connections 가 메모리에 비례하므로 태스크 수 × Hikari 풀(기본 10)보다 커야 한다.
variable "generation" {
  description = "서버 세대. G3 는 스토리지가 CB2 다"
  type        = string
  default     = "G3"
}

variable "server_type" {
  description = "사양 타입 (STAND = Standard)"
  type        = string
  default     = "STAND"
}

variable "vcpu" {
  description = "vCPU 수"
  type        = number
  default     = 2
}

variable "memory_gb" {
  description = "메모리 (GB)"
  type        = number
  default     = 8
}

variable "allow_amd" {
  description = "false 면 AMD 이미지 · 사양을 빼고 x86 을 쓴다"
  type        = bool
  default     = false
}

variable "engine_version_prefix" {
  description = "MySQL 엔진 버전. 이 접두사에 맞는 가장 최신 이미지를 쓴다 (앱은 8.4 기준)"
  type        = string
  default     = "8.4"
}

variable "port" {
  description = "접속 포트. 3306 또는 10000~20000"
  type        = number
  default     = 3306
}

variable "is_ha" {
  description = "HA (스탠바이 서버 추가, 요금 2배). 단기 운영이라 기본은 끈다"
  type        = bool
  default     = false
}

variable "password_version" {
  description = "올리면 모든 계정 비밀번호를 새로 만든다"
  type        = number
  default     = 1
}
