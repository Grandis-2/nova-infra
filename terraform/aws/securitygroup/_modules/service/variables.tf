variable "name_prefix" {
  description = "리소스 이름 접두사 (nova-prod)"
  type        = string
}

variable "name" {
  description = "서비스 이름 (service.yml 의 name)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "alb_security_group_id" {
  description = "ALB 보안 그룹. alb_ports 가 비어 있으면 쓰지 않는다"
  type        = string
}

variable "alb_ports" {
  description = "ALB 가 이 서비스로 여는 포트 (앱 포트 · 헬스체크 포트). ALB 뒤에 없으면 []"
  type        = list(number)
  default     = []
}

variable "use_cache" {
  description = "이 서비스가 Valkey 를 쓰는지 (service.yml 의 redis)"
  type        = bool
  default     = false
}

variable "cache_security_group_id" {
  description = "Valkey 보안 그룹"
  type        = string
}

variable "vpce_security_group_id" {
  description = "VPC 인터페이스 엔드포인트 보안 그룹"
  type        = string
}
