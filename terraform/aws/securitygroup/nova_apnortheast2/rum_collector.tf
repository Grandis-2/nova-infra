# 브라우저 수집기 — 프런트(Grafana Faro)가 rum.<도메인>/collect 로 보낸 것을 받아 검사 · 정리한 뒤 OTel 게이트웨이로 넘기는 Collector.
# 태스크와 ALB 대상 그룹 · 규칙은 monitoring/lgtm 스택이 만든다. 공개 수집 경로라 게이트웨이와 따로 둬서, 몰려도 여기서만 버린다.
#
# 인바운드  12347(faro) · 13133(헬스 체크) — ALB 에서만
# 아웃바운드 게이트웨이 4318(OTLP HTTP, Service Connect), 443(이미지 · 로그 · AWS API)
locals {
  rum_collector_ports = { 12347 = "Faro receiver", 13133 = "health check" }
}

resource "aws_security_group" "rum_collector" {
  name        = "${local.name_prefix}-rum-collector-sg"
  description = "Browser RUM collector: Faro from ALB, export to OTel gateway"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-rum-collector-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rum_collector_from_alb" {
  for_each = local.rum_collector_ports

  security_group_id            = aws_security_group.rum_collector.id
  description                  = "${each.value} from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "alb_to_rum_collector" {
  for_each = local.rum_collector_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "to RUM collector ${each.value}"
  referenced_security_group_id = aws_security_group.rum_collector.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "rum_collector_to_gateway" {
  security_group_id            = aws_security_group.rum_collector.id
  description                  = "OTLP HTTP to OTel gateway"
  referenced_security_group_id = aws_security_group.otel_gateway.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_ingress_rule" "otel_gateway_from_rum_collector" {
  security_group_id            = aws_security_group.otel_gateway.id
  description                  = "OTLP HTTP from RUM collector"
  referenced_security_group_id = aws_security_group.rum_collector.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

# 이미지(Docker Hub) · CloudWatch Logs · AWS API. 대상 주소가 고정되지 않아 0.0.0.0/0 이다
resource "aws_vpc_security_group_egress_rule" "rum_collector_https" {
  security_group_id = aws_security_group.rum_collector.id
  description       = "HTTPS to image registries, CloudWatch Logs, AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 인터페이스 엔드포인트를 켜면 그쪽으로 붙는다 (엔드포인트 SG 는 vpc 스택 소유)
resource "aws_vpc_security_group_ingress_rule" "vpce_from_rum_collector" {
  security_group_id            = local.vpce_sg_id
  description                  = "from RUM collector (AWS APIs)"
  referenced_security_group_id = aws_security_group.rum_collector.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
