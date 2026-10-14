variable "domain_name" {
  description = "서비스 도메인. 비우면 인증서를 만들지 않는다"
  type        = string
  default     = ""
}

variable "subject_alternative_names" {
  description = "CloudFront 인증서에만 넣는 추가 도메인 (예: cdn). ALB 인증서는 domain_name 과 origin 이름만 쓴다"
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "DNS 검증 레코드를 넣을 호스팅 영역 ID. 비우면 route53_zone_name 으로 찾는다"
  type        = string
  default     = ""
}

variable "route53_zone_name" {
  description = "호스팅 영역 이름. domain_name 이 하위 도메인이면 상위 영역을 적는다 (예: grandis-nova.link). 비우면 domain_name"
  type        = string
  default     = ""
}

variable "grafana_domain_name" {
  description = "Grafana 공개 주소(NV-517). 비우면 Grafana 인증서를 만들지 않는다"
  type        = string
  default     = ""
}
