# OTel 게이트웨이 — 앱의 OTLP 를 받아 샘플링 · 마스킹 · APM 지표를 만들고 obs 의 Loki · Tempo · Mimir 로 보내는 Collector(NV-543).
# 태스크는 monitoring/lgtm 스택이 만들고, 서비스 SG 를 참조해야 해서 SG 는 여기 둔다.
#
# 인바운드  4317 · 4318(OTLP) — 서비스 SG 에서만. 앱은 Service Connect(otel-gateway.<네임스페이스>)로 붙는다
# 아웃바운드 obs 의 Loki 3100 · Tempo OTLP 14317 · Mimir 9009 (Service Connect), 443(이미지 · 로그 · AWS API)
locals {
  otel_gateway_obs_ports = { 3100 = "Loki", 14317 = "Tempo OTLP", 9009 = "Mimir" }
}

resource "aws_security_group" "otel_gateway" {
  name        = "${local.name_prefix}-otel-gateway-sg"
  description = "OTel gateway collector: OTLP from service tasks, export to obs"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-otel-gateway-sg" }
}

# 키: <서비스 키>-<포트>
resource "aws_vpc_security_group_ingress_rule" "otel_gateway_otlp" {
  for_each = {
    for pair in setproduct(keys(local.services), [4317, 4318]) :
    "${pair[0]}-${pair[1]}" => { service = pair[0], port = pair[1] }
  }

  security_group_id            = aws_security_group.otel_gateway.id
  description                  = "OTLP ${each.value.port == 4317 ? "gRPC" : "HTTP"} from ${local.services[each.value.service].name}"
  referenced_security_group_id = module.service[each.value.service].security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "otel_gateway_to_obs" {
  for_each = local.otel_gateway_obs_ports

  security_group_id            = aws_security_group.otel_gateway.id
  description                  = "to obs ${each.value}"
  referenced_security_group_id = aws_security_group.obs.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_ingress_rule" "obs_from_otel_gateway" {
  for_each = local.otel_gateway_obs_ports

  security_group_id            = aws_security_group.obs.id
  description                  = "${each.value} from OTel gateway"
  referenced_security_group_id = aws_security_group.otel_gateway.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# 이미지(Docker Hub · ECR) · CloudWatch Logs · AWS API. 대상 주소가 고정되지 않아 0.0.0.0/0 이다
resource "aws_vpc_security_group_egress_rule" "otel_gateway_https" {
  security_group_id = aws_security_group.otel_gateway.id
  description       = "HTTPS to image registries, CloudWatch Logs, AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 인터페이스 엔드포인트를 켜면 그쪽으로 붙는다 (엔드포인트 SG 는 vpc 스택 소유)
resource "aws_vpc_security_group_ingress_rule" "vpce_from_otel_gateway" {
  security_group_id            = local.vpce_sg_id
  description                  = "from OTel gateway (AWS APIs)"
  referenced_security_group_id = aws_security_group.otel_gateway.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
