# RDS for MySQL (rds 스택) — NCP 에서 옮겨 오는 DB. db 서브넷에 둔다.
#
# 들어오는 3306 은 DB 를 쓰는 쪽에서만 받는다.
#   ProxySQL(proxysql.tf)        이전 기간에 앱 쿼리를 NCP · RDS 로 보낸다
#   서비스(service.yml 의 db)     전환 뒤 앱이 RDS 에 바로 붙는다 (서비스 모듈이 규칙을 만든다)
#   마이그레이션 태스크 · obs(mysqld_exporter) · bastion(런북)
#
# 나가는 3306 은 RDS 가 NCP 의 binlog 를 받는 복제 기간에만 연다(rds_replication_egress). NCP Public 도메인의 IP 가
# 고정되지 않아 0.0.0.0/0 이고, vpc 스택의 db_subnet_nat_egress 가 NAT-2a 로 보낸다. 전환 뒤 둘 다 끈다
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS for MySQL"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each = {
    proxysql  = aws_security_group.proxysql.id
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

resource "aws_vpc_security_group_egress_rule" "rds_replication" {
  count = var.rds_replication_egress ? 1 : 0

  security_group_id = aws_security_group.rds.id
  description       = "MySQL replication from NCP DB via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}
