# 마이그레이션 태스크 — release 가 서비스 배포 전에 RunTask 로 띄우는 Flyway (ecs 스택 migration.tf).
# 서비스가 아니라 application/ 에 없으므로 SG 를 여기 따로 둔다.
#
# 인바운드는 없다. 나가는 것은 둘이다.
#   3306 — RDS (RDS SG 로만. RDS SG 도 이 SG 에서만 받는다, rds.tf)
#   443  — 이미지 Pull(ECR · S3 게이트웨이 엔드포인트) · 시크릿 · 로그 (엔드포인트 또는 NAT)
resource "aws_security_group" "migration" {
  name        = "${local.name_prefix}-migration-sg"
  description = "Flyway migration task (no inbound)"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-migration-sg" }
}

resource "aws_vpc_security_group_egress_rule" "migration" {
  security_group_id = aws_security_group.migration.id
  description       = "HTTPS to ECR, Secrets Manager, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "migration_db" {
  security_group_id            = aws_security_group.migration.id
  description                  = "MySQL to RDS"
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
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

# 3306 규칙을 RDS SG 로 좁히며 for_each 의 https 인스턴스를 단일 리소스로 옮긴다(다시 만들지 않는다)
moved {
  from = aws_vpc_security_group_egress_rule.migration["https"]
  to   = aws_vpc_security_group_egress_rule.migration
}
