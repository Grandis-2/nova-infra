# 엣지 로그 Lambda(NV-542) — 로그 버킷의 ALB · CloudFront 접근 로그를 읽어 OTel 게이트웨이로 보낸다.
# 함수는 monitoring/lgtm 스택이 만든다. 게이트웨이 SG 에 규칙을 더해야 해서 SG 는 여기 둔다.
#
# 아웃바운드 게이트웨이 4318(OTLP HTTP, otel-ingest.<네임스페이스> DNS 이름), 443(S3 게이트웨이 엔드포인트 · CloudWatch Logs)
resource "aws_security_group" "edge_logs" {
  name        = "${local.name_prefix}-edge-logs-sg"
  description = "Edge log shipper Lambda: read access logs, send OTLP to OTel gateway"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-edge-logs-sg" }
}

resource "aws_vpc_security_group_egress_rule" "edge_logs_to_gateway" {
  security_group_id            = aws_security_group.edge_logs.id
  description                  = "OTLP HTTP to OTel gateway"
  referenced_security_group_id = aws_security_group.otel_gateway.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_ingress_rule" "otel_gateway_from_edge_logs" {
  security_group_id            = aws_security_group.otel_gateway.id
  description                  = "OTLP HTTP from edge log Lambda"
  referenced_security_group_id = aws_security_group.edge_logs.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

# S3(게이트웨이 엔드포인트) · CloudWatch Logs. 대상 주소가 고정되지 않아 0.0.0.0/0 이다
resource "aws_vpc_security_group_egress_rule" "edge_logs_https" {
  security_group_id = aws_security_group.edge_logs.id
  description       = "HTTPS to S3 and CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
