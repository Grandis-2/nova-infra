data "aws_lb" "alb" {
  count = local.origin_over_https ? 1 : 0
  arn   = local.alb_arn
}

# CloudFront 전용 원본 이름. 사용자용 주소가 아니다.
resource "aws_route53_record" "origin" {
  count = local.origin_over_https ? 1 : 0

  zone_id = local.route53_zone_id
  name    = local.origin_host
  type    = "A"

  alias {
    name                   = data.aws_lb.alb[0].dns_name
    zone_id                = data.aws_lb.alb[0].zone_id
    evaluate_target_health = true
  }
}

# 서비스 도메인(api.grandis-nova.link) → CloudFront
resource "aws_route53_record" "apex" {
  # IPv6 를 켰으므로 AAAA 도 만든다
  for_each = local.use_domain && local.route53_zone_id != "" ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.route53_zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
