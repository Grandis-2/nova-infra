# RDS for MySQL (rds 스택) — 운영 DB. db 서브넷에 둔다.
#
# 들어오는 3306 은 DB 를 쓰는 쪽에서만 받는다.
#   서비스(service.yml 의 db)     서비스 모듈이 규칙을 만든다
#   마이그레이션 태스크 · obs(mysqld_exporter) · bastion
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS for MySQL"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each = {
    migration = aws_security_group.migration.id
    obs       = aws_security_group.obs.id
    bastion   = aws_security_group.bastion.id
  }

  security_group_id            = aws_security_group.rds.id
  description                  = "from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

