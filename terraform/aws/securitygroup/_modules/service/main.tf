# 서비스 하나의 보안 그룹과, 그 서비스에 관한 규칙을 모은다.
# 서비스끼리의 호출 규칙은 서로를 참조해야 해서 스택(main.tf)에 둔다.

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-${var.name}-sg"
  description = "${var.name} tasks"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-${var.name}-sg" }
}

# 앱 서브넷은 인터넷에서 들어올 경로가 없다. 외부 호출 · 이미지 Pull 은 NAT(또는 VPC 엔드포인트)로 나간다
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "all outbound via NAT / VPC endpoint"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ── ALB ↔ 서비스 (앱 포트 · 헬스체크 포트) ───────────────────
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  for_each = toset([for p in var.alb_ports : tostring(p)])

  security_group_id            = aws_security_group.this.id
  description                  = "from ALB"
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  for_each = toset([for p in var.alb_ports : tostring(p)])

  security_group_id            = var.alb_security_group_id
  description                  = "to ${var.name} tasks"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

# ── 서비스 → Valkey ─────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "to_cache" {
  # 개수는 plan 때 알아야 한다 — 아직 없는 SG 의 ID 로 정하면 plan 이 실패한다
  count = var.use_cache ? 1 : 0

  security_group_id            = var.cache_security_group_id
  description                  = "from ${var.name} tasks"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

# ── 서비스 → DB ─────────────────────────────────────────────
# DB(RDS) SG 에 이 서비스의 3306 을 연다
resource "aws_vpc_security_group_ingress_rule" "to_db" {
  # 키(rds)는 plan 때 알고 있다. 값(SG ID)은 아직 없어도 된다
  for_each = var.use_db ? var.db_security_group_ids : {}

  security_group_id            = each.value
  description                  = "from ${var.name} tasks"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# ── 서비스 → VPC 인터페이스 엔드포인트 ──────────────────────
resource "aws_vpc_security_group_ingress_rule" "to_vpce" {
  security_group_id            = var.vpce_security_group_id
  description                  = "from ${var.name} tasks"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
