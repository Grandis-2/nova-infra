# Atlantis 를 메인 ALB 뒤에서 받는다. Atlantis 태스크는 atlantis-deploy 저장소가 만들고, 이 SG 를 태스크에 더 붙인다.
# 메인 ALB SG 를 참조해야 해서 여기 둔다(atlantis-deploy 가 메인 ALB SG 를 직접 고치지 않게).
#
# 인바운드 4141(Atlantis) — 메인 ALB 에서만
resource "aws_security_group" "atlantis" {
  name        = "${local.name_prefix}-atlantis-ingress-sg"
  description = "Atlantis tasks: web and webhooks from the main ALB"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-atlantis-ingress-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "atlantis_from_alb" {
  security_group_id            = aws_security_group.atlantis.id
  description                  = "Atlantis from main ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 4141
  to_port                      = 4141
}

resource "aws_vpc_security_group_egress_rule" "alb_to_atlantis" {
  security_group_id            = aws_security_group.alb.id
  description                  = "to Atlantis tasks"
  referenced_security_group_id = aws_security_group.atlantis.id
  ip_protocol                  = "tcp"
  from_port                    = 4141
  to_port                      = 4141
}
