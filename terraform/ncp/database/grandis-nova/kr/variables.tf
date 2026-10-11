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

# 서버 이미지 · 사양 — 바꾸면 DB 를 교체한다. 목록은 ncloud_mysql_image_products · ncloud_mysql_products 로 조회한다.
# max_connections 가 메모리에 비례하므로 태스크 수 × Hikari 풀(기본 10)보다 커야 한다.
variable "image_product_code" {
  description = "MySQL 서버 이미지 (G3, Rocky 8)"
  type        = string
  default     = "SW.VMYSL.OS.LNX64.ROCKY.08.MYSQL.B050.G003"
}

variable "product_code" {
  description = "서버 사양 (G3 Standard, vCPU 2EA · Memory 8GB, AMD). G3 MySQL 이미지에는 AMD 모델만 있다"
  type        = string
  default     = "SVR.VDBAS.AMD.STAND.C002.M008.NET.SSD.B050.G003"
}

variable "engine_version_prefix" {
  description = "MySQL 엔진 버전대. 생성할 때 이 버전대의 엔진을 쓴다 (앱은 8.4 기준). 이후 변경은 무시된다"
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
