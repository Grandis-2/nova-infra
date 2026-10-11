# 관측 호스트(obs) — OTel Collector · Loki · Grafana 를 docker compose 로 띄우는 EC2 (Grandis-2/nova-observability).
# 인스턴스는 obs 스택이 만들고, 이 SG 만 여기 둔다 (서비스 SG 를 참조해야 해서).
#
# 인바운드는 OTLP 두 포트(4317 gRPC · 4318 HTTP)를 서비스 SG 참조로만 연다.
# Grafana(3000) · SSH(22) 는 열지 않는다. 사람은 SSM Session Manager 포트 포워딩으로 들어온다.
resource "aws_security_group" "obs" {
  name        = "${local.name_prefix}-obs-sg"
  description = "Observability host: OTLP from service tasks only"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-obs-sg" }
}

# 키: <서비스 키>-<포트>
resource "aws_vpc_security_group_ingress_rule" "obs_otlp" {
  for_each = {
    for pair in setproduct(keys(local.services), [4317, 4318]) :
    "${pair[0]}-${pair[1]}" => { service = pair[0], port = pair[1] }
  }

  security_group_id            = aws_security_group.obs.id
  description                  = "OTLP ${each.value.port == 4317 ? "gRPC" : "HTTP"} from ${local.services[each.value.service].name}"
  referenced_security_group_id = module.service[each.value.service].security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# 나가는 것은 443 하나다.
#   S3 (게이트웨이 엔드포인트, Loki 저장소) · SSM · Secrets Manager (NAT)
#   NAT 를 거쳐 dnf 저장소(AL2023 은 HTTPS) · 컨테이너 이미지 레지스트리 · GitHub (설정 내려받기)
# 대상 주소가 고정되지 않아 0.0.0.0/0 이다. VPC DNS · 시간 동기화 · IMDS 는 SG 가 거르지 않는다.
resource "aws_vpc_security_group_egress_rule" "obs_https" {
  security_group_id = aws_security_group.obs.id
  description       = "HTTPS to AWS APIs, S3 gateway endpoint, package and image registries, GitHub"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 인터페이스 엔드포인트를 켜면 SSM 에이전트가 엔드포인트로 붙는다 (엔드포인트 SG 는 vpc 스택 소유)
resource "aws_vpc_security_group_ingress_rule" "vpce_from_obs" {
  security_group_id            = local.vpce_sg_id
  description                  = "from obs host (SSM agent, AWS APIs)"
  referenced_security_group_id = aws_security_group.obs.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
