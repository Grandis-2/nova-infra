variable "grafana_domain_name" {
  description = "Grafana 공개 주소. acm 스택의 grafana_domain_name 과 같아야 한다 (같은 층이라 remote state 로 읽지 않는다)"
  type        = string
}
