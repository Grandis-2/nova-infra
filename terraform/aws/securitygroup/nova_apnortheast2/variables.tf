variable "alb_origin_https" {
  description = <<-EOT
    CloudFront 가 ALB 에 HTTPS 로 붙는지. edge 스택의 origin_over_https 와 같아야 한다.
    도메인, CloudFront 인증서, Route 53 영역이 모두 있어야 true. false 면 80 만 연다.
  EOT
  type        = bool
  default     = false
}

variable "admin_cidrs" {
  description = "Bastion 등 운영 접근을 허용할 IP 대역. SSM 을 쓰면 비워둔다"
  type        = list(string)
  default     = []
}

variable "cloudfront_prefix_list_id" {
  description = "CloudFront 오리진 prefix list 를 직접 지정할 때 쓴다. 비우면 이름으로 조회한다"
  type        = string
  default     = ""
}

variable "rds_replication_egress" {
  description = "RDS 가 NCP 로 3306 을 내보낸다(NCP → RDS 복제). 복제 기간에만 켜고 전환 뒤 끈다 (rds.tf)"
  type        = bool
  default     = false
}
