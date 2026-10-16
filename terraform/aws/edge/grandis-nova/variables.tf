variable "domain_name" {
  description = "서비스 도메인. 비우면 CloudFront 기본 도메인을 쓴다"
  type        = string
  default     = ""
}

variable "cloudfront_certificate_arn" {
  description = "us-east-1 ACM 인증서 ARN (acm 스택 output). 도메인을 쓸 때만 필요"
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "A 레코드를 만들 호스팅 영역. 비우면 DNS 레코드를 만들지 않는다"
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront 엣지 범위. PriceClass_200 이면 한국·일본 포함"
  type        = string
  default     = "PriceClass_200"
}

variable "api_rate_limit_per_5min" {
  description = "IP 하나가 5분 동안 보낼 수 있는 요청 수. 넘으면 차단"
  type        = number
  default     = 3000
}

variable "queue_rate_limit_per_5min" {
  description = "IP 하나가 5분 동안 대기열(/api/v1/preorders/queue, 줄 서기 · 조회)로 보낼 수 있는 요청 수. 넘으면 차단"
  type        = number
  default     = 300000
}

variable "rum_rate_limit_per_5min" {
  description = "IP 하나가 5분 동안 브라우저 수집 주소(rum.<도메인>/collect)로 보낼 수 있는 요청 수. 넘으면 차단"
  type        = number
  # 한 사용자가 5분 동안 보내는 묶음은 수십 건이다. 회사 · 학교 NAT 뒤 수십 명까지 막히지 않게 둔다
  default = 3000
}

variable "waf_block_mode" {
  description = "true 면 차단, false 면 집계만(Count). 도입 초기에는 false 로 지켜본다"
  type        = bool
  default     = true
}

variable "route53_zone_name" {
  description = "domain_name 의 레코드를 만들 호스팅 영역 (예: grandis-nova.link). domain_name 을 쓰고 route53_zone_id 가 없으면 필수"
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || var.route53_zone_id != "" || (var.route53_zone_name != "" && (var.domain_name == var.route53_zone_name || endswith(var.domain_name, ".${var.route53_zone_name}")))
    error_message = "domain_name 을 쓰면 route53_zone_id 나, 그 도메인을 담는 route53_zone_name 을 지정해야 합니다."
  }
}
