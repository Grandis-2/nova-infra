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

variable "product_code" {
  description = <<-EOT
    서버 사양 코드. null 이면 최소 사양. 목록은 ncloud_mysql_products 데이터 소스로 확인한다.
    max_connections 가 메모리에 비례하므로 태스크 수 × Hikari 풀(기본 10)보다 커야 한다.
  EOT
  type        = string
  default     = null
}

variable "engine_version_code" {
  description = "MySQL 엔진 버전 코드. null 이면 NCP 기본값 (앱은 8.4 기준)"
  type        = string
  default     = null
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
