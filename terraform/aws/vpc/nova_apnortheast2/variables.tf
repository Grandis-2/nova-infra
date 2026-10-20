variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR (availability_zones 순서)"
  type        = list(string)
}

variable "app_subnet_cidrs" {
  description = "앱(프라이빗) 서브넷 CIDR"
  type        = list(string)
}

variable "db_subnet_cidrs" {
  description = "DB(격리) 서브넷 CIDR"
  type        = list(string)
}

variable "nat_mode" {
  description = "instance = EC2 NAT 인스턴스(fck-nat, 저렴) | gateway = NAT 게이트웨이(관리형)"
  type        = string
  default     = "instance"

  validation {
    condition     = contains(["instance", "gateway"], var.nat_mode)
    error_message = "nat_mode 는 instance 또는 gateway 여야 한다."
  }
}

variable "nat_instance_type" {
  description = "NAT 인스턴스 크기. DB 트래픽도 지나가므로 기본 대역폭이 큰 micro 를 쓴다"
  type        = string
  default     = "t4g.micro"
}

variable "single_nat_gateway" {
  description = <<-EOT
    NAT 를 하나만 둔다(두 모드 공통). NAT 요금이 절반이 되지만 그 AZ 가 죽으면
    다른 AZ 의 아웃바운드도 끊기고 AZ 간 전송 요금이 붙는다. 운영은 false.
  EOT
  type        = bool
  default     = false
}

variable "db_subnet_nat_egress" {
  description = <<-EOT
    db 서브넷의 0.0.0.0/0 을 첫 NAT(2a)로 보낸다. 2026-10-20 NCP → RDS 복제 기간에만 켰다.
    다시 켤 때는 RDS SG 에 필요한 아웃바운드 규칙도 함께 둔다.
  EOT
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Interface VPC Endpoint 생성 여부. NAT 로도 나갈 수 있어 선택 사항이고 시간당 요금이 붙는다"
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Interface Endpoint 서비스 이름 (com.amazonaws.<region>. 제외)"
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]
}

variable "enable_flow_logs" {
  description = "VPC Flow Logs 를 CloudWatch 로 보낼지 여부"
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Flow Logs 보관 기간(일)"
  type        = number
  default     = 14
}
