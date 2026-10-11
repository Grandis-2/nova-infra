variable "alb_certificate_arn" {
  description = "ALB 용 ACM 인증서 ARN(서울 리전). 비우면 HTTPS 리스너를 만들지 않는다"
  type        = string
  default     = ""
}

variable "namespace_name" {
  description = "Cloud Map private DNS 네임스페이스"
  type        = string
  default     = "nova.local" # 서비스 주소는 환경변수로 넣으므로 앱 기본 설정과 달라도 된다
}

variable "log_retention_days" {
  description = "컨테이너 로그 보관 기간(일)"
  type        = number
  default     = 14
}

variable "container_insights" {
  description = "enhanced | enabled | disabled. enhanced 는 태스크 단위 지표까지 본다"
  type        = string
  default     = "enabled"
}

variable "spring_profile" {
  description = "SPRING_PROFILES_ACTIVE 값"
  type        = string
  default     = "prod"
}

variable "enable_alb_access_logs" {
  description = "ALB 액세스 로그를 로그 버킷에 남길지 여부"
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "ALB 삭제 방지. 상시 운영이므로 켠다. 스택을 지워야 할 때만 false 로 바꿔 먼저 apply 한다"
  type        = bool
  default     = true
}

variable "cpu_architecture" {
  description = <<-EOT
    태스크 CPU 아키텍처. 이미지를 빌드한 플랫폼과 같아야 한다.
    arm64 이미지를 빌드하면 ARM64(Graviton, 약 20% 저렴)로 바꿀 수 있다.
  EOT
  type        = string
  default     = "X86_64"
}

variable "spot_on_demand_base" {
  description = <<-EOT
    Spot 서비스마다 온디맨드로 남길 태스크 수. 0 이면 전부 Spot.
    Spot 회수로 서비스가 잠깐 비는 것을 막으려면 1.
  EOT
  type        = number
  default     = 0
}

variable "db_ssl_mode" {
  description = <<-EOT
    JDBC sslMode. DB 가 인터넷 너머(NCP Public 도메인)에 있어 기본값은 REQUIRED 다.
    DB 가 TLS 를 지원하지 않으면 연결이 실패한다. 이때 PREFERRED 로 낮출 수 있지만
    DB 트래픽이 평문으로 인터넷을 지나게 된다.
  EOT
  type        = string
  default     = "REQUIRED"

  validation {
    condition     = contains(["REQUIRED", "VERIFY_CA", "VERIFY_IDENTITY", "PREFERRED", "DISABLED"], var.db_ssl_mode)
    error_message = "db_ssl_mode 는 MySQL Connector/J 의 sslMode 값이어야 합니다."
  }
}
