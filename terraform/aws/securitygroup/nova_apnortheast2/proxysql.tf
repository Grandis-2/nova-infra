# ProxySQL (ecs 스택 proxysql.tf) — RDS 이전 기간에만 앱과 DB 사이에 둔다. 전환 순간 쿼리를 잠깐 세워 두고
# 쓰기 대상을 NCP 에서 RDS 로 바꾼다. 전환이 끝나면 앱이 RDS 에 바로 붙고 ProxySQL 은 지운다.
#
#   앱(service.yml 의 db) → NLB 3306 → ProxySQL 3306 → NCP(NAT) · RDS
#   bastion(런북) → ProxySQL 관리 포트 6032 (태스크 IP 로 바로 붙는다. NLB 로는 열지 않는다)
#
# NLB 에 SG 를 붙여 ProxySQL 이 NLB SG 만 믿게 한다. NLB 는 출발지 IP 를 바꾸므로 서비스 SG 로는 거를 수 없다.
# NLB SG 는 만든 뒤 붙이거나 뗄 수 없어 ecs 스택이 NLB 를 만들 때부터 붙인다

resource "aws_security_group" "proxysql_nlb" {
  name        = "${local.name_prefix}-proxysql-nlb-sg"
  description = "Internal NLB in front of ProxySQL"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-proxysql-nlb-sg" }
}

# 서비스 → NLB 는 서비스 모듈이 만든다. bastion 은 시험 클라이언트(프로브)로 같은 경로를 쓴다
resource "aws_vpc_security_group_ingress_rule" "proxysql_nlb_from_bastion" {
  security_group_id            = aws_security_group.proxysql_nlb.id
  description                  = "from bastion (probe)"
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "proxysql_nlb_to_proxysql" {
  security_group_id            = aws_security_group.proxysql_nlb.id
  description                  = "to ProxySQL tasks (traffic and health checks)"
  referenced_security_group_id = aws_security_group.proxysql.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_security_group" "proxysql" {
  name        = "${local.name_prefix}-proxysql-sg"
  description = "ProxySQL tasks"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-proxysql-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "proxysql" {
  for_each = {
    nlb   = { sg = aws_security_group.proxysql_nlb.id, port = 3306, description = "MySQL from NLB" }
    admin = { sg = aws_security_group.bastion.id, port = 6032, description = "admin interface from bastion (runbook)" }
  }

  security_group_id            = aws_security_group.proxysql.id
  description                  = each.value.description
  referenced_security_group_id = each.value.sg
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# 3306 — NCP(NAT 고정 IP 로 나가야 ACG 를 지난다)와 RDS. NCP Public 도메인의 IP 가 고정되지 않아 0.0.0.0/0 이다
# 443  — 이미지 Pull(ECR · Docker Hub) · 시크릿 · SSM 파라미터 · 로그 (엔드포인트 또는 NAT)
resource "aws_vpc_security_group_egress_rule" "proxysql" {
  for_each = { db = 3306, https = 443 }

  security_group_id = aws_security_group.proxysql.id
  description       = each.key == "db" ? "MySQL to NCP DB via NAT and RDS" : "HTTPS to image registries, Secrets Manager, SSM, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_proxysql" {
  security_group_id            = local.vpce_sg_id
  description                  = "from ProxySQL tasks (ECR, Secrets Manager, SSM, Logs)"
  referenced_security_group_id = aws_security_group.proxysql.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
