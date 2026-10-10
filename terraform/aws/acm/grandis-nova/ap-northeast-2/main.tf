# route53_zone_id 가 없으면 route53_zone_name(없으면 domain_name)으로 호스팅 영역을 찾는다
data "aws_route53_zone" "this" {
  count = var.domain_name != "" && var.route53_zone_id == "" ? 1 : 0

  name         = var.route53_zone_name != "" ? var.route53_zone_name : var.domain_name
  private_zone = false
}

locals {
  route53_zone_id = var.route53_zone_id != "" ? var.route53_zone_id : try(data.aws_route53_zone.this[0].zone_id, "")
}

# TLS 인증서. 리전별로 한 장씩 필요하다.
#   ap-northeast-2 : ALB 리스너
#   us-east-1      : CloudFront (이 리전 인증서만 쓸 수 있다)
#
# ecs(ALB)와 edge(CloudFront)가 서로 참조하면 순환이 생기므로 인증서를 별도 스택으로 둔다.

locals {
  enabled = var.domain_name != ""

  # CloudFront 가 ALB 오리진에 접속할 때 쓰는 이름. ALB 인증서에 있어야
  # CloudFront → ALB 구간에서 HTTPS 인증서 검증이 통과한다.
  origin_host = "origin.${var.domain_name}"
}

resource "aws_acm_certificate" "alb" {
  count = local.enabled ? 1 : 0

  # ALB 가 받는 이름만 넣는다. cdn 등 CloudFront 전용 이름(subject_alternative_names)은 cloudfront 인증서에만
  domain_name               = var.domain_name
  subject_alternative_names = [local.origin_host]
  validation_method         = "DNS"

  tags = { Name = "${local.name_prefix}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1
  count    = local.enabled ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  tags = { Name = "${local.name_prefix}-cloudfront" }

  lifecycle {
    create_before_destroy = true
  }
}

# 두 인증서의 검증 레코드를 도메인별로 하나씩만 만든다.
# 키는 변수로 이미 아는 도메인 목록으로 정한다 — 인증서를 만들기 전에는 검증 정보를 몰라서,
# 그걸로 키를 만들면 첫 plan 이 for_each 를 계산하지 못해 실패한다.
# ACM 은 같은 계정 · 도메인에 같은 검증 레코드를 주므로 두 인증서가 한 레코드를 같이 쓴다.
locals {
  validation_domains = local.enabled && local.route53_zone_id != "" ? toset(distinct(concat(
    [var.domain_name], var.subject_alternative_names, [local.origin_host],
  ))) : toset([])

  validation_options = local.enabled ? concat(
    tolist(aws_acm_certificate.alb[0].domain_validation_options),
    tolist(aws_acm_certificate.cloudfront[0].domain_validation_options),
  ) : []
}

resource "aws_route53_record" "validation" {
  for_each = local.validation_domains

  zone_id         = local.route53_zone_id
  name            = [for o in local.validation_options : o.resource_record_name if o.domain_name == each.key][0]
  type            = [for o in local.validation_options : o.resource_record_type if o.domain_name == each.key][0]
  ttl             = 60
  records         = [[for o in local.validation_options : o.resource_record_value if o.domain_name == each.key][0]]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count = local.enabled && local.route53_zone_id != "" ? 1 : 0

  certificate_arn = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [
    for opt in aws_acm_certificate.alb[0].domain_validation_options :
    aws_route53_record.validation[opt.domain_name].fqdn
  ]
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1
  count    = local.enabled && local.route53_zone_id != "" ? 1 : 0

  certificate_arn = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [
    for opt in aws_acm_certificate.cloudfront[0].domain_validation_options :
    aws_route53_record.validation[opt.domain_name].fqdn
  ]
}
