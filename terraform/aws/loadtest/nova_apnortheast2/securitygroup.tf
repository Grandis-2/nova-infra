# 시험 태스크 SG. 셋 다 인바운드는 없다.
#   k6         public 서브넷 · 공인 IP. 443(API · 이미지 · S3 · 로그), 게이트웨이 4318(지표, otel-ingest.<네임스페이스>)
#   controller app 서브넷. 443(ECS · S3 · CloudWatch API), obs 9009(Mimir 조회. 태스크 IP 로 직접 붙는다)
#   minter     app 서브넷. 443(이미지 · Secrets Manager · S3 · 로그)
# 443 은 대상 주소가 고정되지 않아 0.0.0.0/0 이다.
#
# 다른 스택의 SG(게이트웨이 · obs · 엔드포인트)에 들어오는 규칙도 여기서 더한다. 규칙을 따로 만드는 리소스라
# 그 SG 를 가진 스택과 다투지 않는다. securitygroup 스택의 게이트웨이 · obs 주석에 이 예외가 적혀 있다.
locals {
  gateway_sg_id = data.terraform_remote_state.security.outputs.otel_gateway_security_group_id
  obs_sg_id     = data.terraform_remote_state.security.outputs.obs_security_group_id
  vpce_sg_id    = data.terraform_remote_state.vpc.outputs.vpce_security_group_id

  task_sg = {
    k6         = "Load test k6 runner (public subnet, no inbound)"
    controller = "Load test controller (no inbound)"
    minter     = "Load test token minter (no inbound)"
  }
}

resource "aws_security_group" "task" {
  for_each = local.task_sg

  name        = "${local.loadtest_name}-${each.key}-sg"
  description = each.value
  vpc_id      = local.vpc_id

  tags = { Name = "${local.loadtest_name}-${each.key}-sg" }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each = aws_security_group.task

  security_group_id = each.value.id
  description       = "HTTPS to API, image registries, AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 인터페이스 엔드포인트는 꺼져 있지만 엔드포인트 SG 는 늘 있다. 켜는 날 시험 태스크만 AWS API 에 못 붙는 일이 없게 미리 연다
resource "aws_vpc_security_group_ingress_rule" "vpce" {
  for_each = aws_security_group.task

  security_group_id            = local.vpce_sg_id
  description                  = "from load test ${each.key} (AWS APIs)"
  referenced_security_group_id = each.value.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# k6 지표 → 게이트웨이
resource "aws_vpc_security_group_egress_rule" "k6_to_gateway" {
  security_group_id            = aws_security_group.task["k6"].id
  description                  = "OTLP HTTP to OTel gateway"
  referenced_security_group_id = local.gateway_sg_id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_ingress_rule" "gateway_from_k6" {
  security_group_id            = local.gateway_sg_id
  description                  = "OTLP HTTP from load test k6"
  referenced_security_group_id = aws_security_group.task["k6"].id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

# 컨트롤러 → Mimir(감시 · 판정 쿼리). 9009 에는 인증 없는 관리 API 도 함께 열려 있어 이 SG 하나에만 연다
resource "aws_vpc_security_group_egress_rule" "controller_to_mimir" {
  security_group_id            = aws_security_group.task["controller"].id
  description                  = "Mimir query on obs"
  referenced_security_group_id = local.obs_sg_id
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
}

resource "aws_vpc_security_group_ingress_rule" "obs_from_controller" {
  security_group_id            = local.obs_sg_id
  description                  = "Mimir query from load test controller"
  referenced_security_group_id = aws_security_group.task["controller"].id
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
}
