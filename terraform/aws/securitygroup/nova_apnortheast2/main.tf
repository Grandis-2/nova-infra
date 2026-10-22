# 서비스별 보안 그룹 — terraform/application/<서비스>/service.yml 에서 만든다.
# CIDR 대신 출발지 SG 로 허용하므로 태스크 IP 가 바뀌어도 규칙은 그대로다.
#
#   routes 있음    → ALB 에서 앱 포트 · 헬스체크 포트       (모듈)
#   redis 있음     → Valkey 6379                            (모듈)
#   db 있음        → RDS 3306                               (모듈)
#   모든 서비스    → VPC 엔드포인트 443, 아웃바운드 전부     (모듈)
#   calls          → 부르는 서비스에서 불리는 서비스 포트    (아래 service_to_service)

module "service" {
  source   = "../_modules/service"
  for_each = local.services

  name_prefix            = local.name_prefix
  name                   = each.value.name
  vpc_id                 = local.vpc_id
  vpce_security_group_id = local.vpce_sg_id

  alb_security_group_id   = aws_security_group.alb.id
  alb_ports               = length(each.value.routes) > 0 ? distinct([each.value.port, each.value.health.port]) : []
  use_cache               = each.value.redis != null
  cache_security_group_id = aws_security_group.redis.id

  use_db = each.value.db != null
  db_security_group_ids = {
    rds = aws_security_group.rds.id
  }
}

# 서비스끼리의 호출 (calls + JWT 검증 서비스 → member). 키: <부르는 쪽>-to-<불리는 쪽>
# 서로를 참조하므로 모듈 밖에 둔다
resource "aws_vpc_security_group_ingress_rule" "service_to_service" {
  for_each = local.service_calls

  security_group_id            = module.service[each.value.callee].security_group_id
  description                  = "from ${local.services[each.value.caller].name}"
  referenced_security_group_id = module.service[each.value.caller].security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.services[each.value.callee].port
  to_port                      = local.services[each.value.callee].port
}
