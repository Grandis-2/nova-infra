# 마이그레이션 태스크 — release 가 서비스 배포 전에 RunTask 로 띄우는 Flyway (ecs 스택 migration.tf).
# 서비스가 아니라 application/ 에 없으므로 SG 를 여기 따로 둔다.
#
# 인바운드는 없다. 나가는 것은 둘이다.
#   3306 — NCP DB. NAT 고정 IP 로 나가야 ACG 를 지난다. Public 도메인의 IP 가 고정되지 않아 0.0.0.0/0 이다
#   443  — 이미지 Pull(ECR · S3 게이트웨이 엔드포인트) · 시크릿 · 로그 (엔드포인트 또는 NAT)
resource "aws_security_group" "migration" {
  name        = "${local.name_prefix}-migration-sg"
  description = "Flyway migration task (no inbound)"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-migration-sg" }
}

resource "aws_vpc_security_group_egress_rule" "migration" {
  for_each = { db = 3306, https = 443 }

  security_group_id = aws_security_group.migration.id
  description       = each.key == "db" ? "MySQL to NCP DB via NAT" : "HTTPS to ECR, Secrets Manager, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# 인터페이스 엔드포인트로 붙는 AWS API (엔드포인트 SG 는 vpc 스택 소유)
resource "aws_vpc_security_group_ingress_rule" "vpce_from_migration" {
  security_group_id            = local.vpce_sg_id
  description                  = "from migration task (ECR, Secrets Manager, Logs)"
  referenced_security_group_id = aws_security_group.migration.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
