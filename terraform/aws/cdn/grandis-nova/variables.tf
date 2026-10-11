variable "domain_name" {
  description = "이미지 도메인. acm 스택의 CloudFront 인증서에 포함돼야 한다. 비우면 *.cloudfront.net 을 쓴다"
  type        = string
  default     = ""
}

variable "route53_zone_name" {
  description = "domain_name 의 레코드를 만들 호스팅 영역"
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront 엣지 범위. PriceClass_200 이면 한국·일본 포함"
  type        = string
  default     = "PriceClass_200"
}

variable "cache_ttl_seconds" {
  description = "엣지 캐시 기본 수명. 이미지를 바꿀 때는 새 키로 올리므로 길게 둔다"
  type        = number
  default     = 2592000 # 30일
}
