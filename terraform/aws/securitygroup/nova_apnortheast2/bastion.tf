# SSH 포트는 열지 않는다. Session Manager 로 접속하고 포트포워딩한다
resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Bastion via SSM (no inbound)"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-bastion-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_admin" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.bastion.id
  description       = "emergency SSH from admin network"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# SSM 에이전트가 VPC 엔드포인트로 붙는다 (엔드포인트 SG 는 vpc 스택 소유)
resource "aws_vpc_security_group_ingress_rule" "vpce_from_bastion" {
  security_group_id            = local.vpce_sg_id
  description                  = "from bastion (SSM agent)"
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
