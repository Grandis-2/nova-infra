# route53_zone_id 가 없으면 route53_zone_name 으로 호스팅 영역을 찾는다
data "aws_route53_zone" "this" {
  count = var.domain_name != "" && var.route53_zone_id == "" ? 1 : 0

  name         = var.route53_zone_name
  private_zone = false
}

locals {
  route53_zone_id = var.route53_zone_id != "" ? var.route53_zone_id : try(data.aws_route53_zone.this[0].zone_id, "")

  # 변수가 비면 acm 스택 인증서를 쓴다
  cloudfront_certificate_arn = var.cloudfront_certificate_arn != "" ? var.cloudfront_certificate_arn : data.terraform_remote_state.acm.outputs.cloudfront_certificate_arn
}

# ─────────────────────────────────────────────────────────────
# edge — API 앞단 CloudFront · WAF · DNS  (api.grandis-nova.link)
#
#   모든 경로 → ALB (캐시 없음, 헤더/쿠키/쿼리 전부 전달)
#
# 프런트는 Vercel 이 호스팅하므로 정적 원본이 없다. 업로드 이미지는 cdn 스택이 맡는다.
# ALB 보안 그룹이 CloudFront prefix list 만 허용하므로 사용자는 CloudFront 를 거쳐야 ALB 에 닿는다.
#
# WAF 는 두 곳에 건다.
#   CloudFront(글로벌) : 봇과 악성 요청을 엣지에서 끊는다
#   ALB(리전)          : 우회 경로가 생겨도 원본 앞에서 한 번 더 막는다
# ─────────────────────────────────────────────────────────────

locals {
  log_bucket   = data.terraform_remote_state.s3.outputs.log_bucket
  alb_dns_name = data.terraform_remote_state.ecs.outputs.alb_dns_name
  alb_arn      = data.terraform_remote_state.ecs.outputs.alb_arn

  use_domain = var.domain_name != ""
  aliases    = local.use_domain ? [var.domain_name] : []

  # 도메인과 호스팅 영역이 있으면 origin.<도메인> 으로 HTTPS 연결한다.
  # 없으면 ALB DNS 이름으로 HTTP 연결한다 (ALB 기본 이름에 맞는 인증서가 없다).
  origin_over_https = local.use_domain && local.route53_zone_id != ""
  origin_host       = local.origin_over_https ? "origin.${var.domain_name}" : local.alb_dns_name

  origin_verify = data.terraform_remote_state.ecs.outputs.origin_verify_header

  waf_override = var.waf_block_mode ? "none" : "count"
}
