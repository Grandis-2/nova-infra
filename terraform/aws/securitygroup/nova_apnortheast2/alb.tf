# CloudFront 오리진 IP 대역 (AWS 관리형이라 갱신할 필요가 없다)
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  count = var.cloudfront_prefix_list_id == "" ? 1 : 0

  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  # CloudFront → ALB 는 포트 하나만 연다 (edge 의 origin_protocol_policy 와 맞춘다).
  # 관리형 prefix list 는 항목 수(약 55)만큼 SG 규칙 한도를 차지해서,
  # 80 과 443 을 둘 다 열면 기본 한도(60)를 넘어 apply 가 실패한다.
  alb_origin_port = var.alb_origin_https ? 443 : 80

  cloudfront_prefix_list_id = (
    var.cloudfront_prefix_list_id != ""
    ? var.cloudfront_prefix_list_id
    : data.aws_ec2_managed_prefix_list.cloudfront_origin[0].id
  )
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Application Load Balancer"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront origin-facing only"
  prefix_list_id    = local.cloudfront_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = local.alb_origin_port
  to_port           = local.alb_origin_port
}

# ALB → 서비스 아웃바운드는 서비스 모듈이 서비스마다 만든다
