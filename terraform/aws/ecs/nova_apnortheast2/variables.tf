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

# 끈다. 태스크 수 · CPU · 메모리는 무료 AWS/ECS 지표(LiveTaskCount · CPUUtilization · MemoryUtilization)로 보고,
# 배포 실패, 태스크 배치 · 설정 실패, 필수 컨테이너 종료 · 기동 실패 · 헬스체크 실패는 ECS 이벤트 경보(monitoring/cloudwatch)가 알린다.
# Spot 회수로 내려간 태스크는 알리지 않는다(서비스가 다시 띄운다). 켜면 사용자 지정 지표로 과금된다
variable "container_insights" {
  description = "enhanced | enabled | disabled. enhanced 는 태스크 단위 지표까지 본다"
  type        = string
  default     = "disabled"
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

variable "obs_instance_type" {
  description = "관측 스택(obs)을 올리는 EC2. ARM(Graviton) 이어야 한다 (ECS 최적화 AL2023 arm64 AMI)"
  type        = string
  default     = "t4g.large"
}

variable "obs_data_volume_size" {
  description = "obs 데이터 EBS 크기(GiB). Loki · Tempo WAL, Mimir TSDB(최근 블록), Grafana DB. 장기 저장은 S3 다"
  type        = number
  default     = 100
}

variable "obs_ami_id" {
  description = "obs 인스턴스 AMI. 비우면 ECS 최적화 AL2023 arm64 최신을 SSM 에서 읽는다"
  type        = string
  default     = ""
}

variable "otel_services" {
  description = <<-EOT
    OTel Java 에이전트를 켤 서비스 키(application/<키>). ["*"] 면 배포하는 서비스 전부.
    에이전트 jar 은 be 이미지(/otel/javaagent.jar)에 있고, 여기 든 서비스에만 JDK_JAVA_OPTIONS 로 켠다 (otel.tf).
    끄려면 목록에서 빼고 apply 한다. 이미지를 다시 만들 필요가 없다.
  EOT
  type        = list(string)
  default     = ["*"] # preorder 에서 확인한 뒤(NV-435) 배포하는 서비스 전부로 넓혔다(NV-438)
}

variable "otel_metrics_enabled" {
  description = "에이전트가 지표도 보낸다. 지표 전송만 끌 때 false (로그 · 트레이스는 그대로)"
  type        = bool
  default     = true
}

variable "mock_admin_allowed_origin" {
  description = "목업 관리 경로(/external/config · faults · reset)를 받아 줄 요청의 Origin 헤더 패턴(ALB 와일드카드). 프런트 도메인(grandis-nova.link · www)"
  type        = string
  default     = "https://*grandis-nova.link"
}
