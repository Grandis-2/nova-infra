# 관측 스택(obs) — monitoring 스택의 ECS 태스크(Collector · Loki · Tempo · Mimir · Grafana · mysqld_exporter, NV-425).
# 태스크는 monitoring 스택이 만들고, 이 SG 만 여기 둔다 (서비스 SG 를 참조해야 해서).
#
# 인바운드는 서비스 SG 참조로만 연다. OTLP 두 포트(4317 gRPC · 4318 HTTP)와 프로파일(4040, Pyroscope · NV-540).
# 앱은 Service Connect(otel.<네임스페이스> · pyroscope.<네임스페이스>)로 붙는다.
# Grafana(3000) 는 ALB 에서만 연다(NV-517). ALB 리스너 규칙이 Cognito 로그인을 거친 요청만 넘긴다.
# (SG 설명 문자열은 바꾸면 SG 가 다시 만들어지므로 처음 값 그대로 둔다)
resource "aws_security_group" "obs" {
  name        = "${local.name_prefix}-obs-sg"
  description = "Observability host: OTLP from service tasks only"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-obs-sg" }
}

# 키: <서비스 키>-<포트>. 리소스 이름은 처음 그대로 둔다(바꾸면 규칙을 지웠다 다시 만든다)
locals {
  obs_inbound_ports = { 4317 = "OTLP gRPC", 4318 = "OTLP HTTP", 4040 = "Pyroscope profiles" }
}

resource "aws_vpc_security_group_ingress_rule" "obs_otlp" {
  for_each = {
    for pair in setproduct(keys(local.services), keys(local.obs_inbound_ports)) :
    "${pair[0]}-${pair[1]}" => { service = pair[0], port = tonumber(pair[1]) }
  }

  security_group_id            = aws_security_group.obs.id
  description                  = "${local.obs_inbound_ports[tostring(each.value.port)]} from ${local.services[each.value.service].name}"
  referenced_security_group_id = module.service[each.value.service].security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

# Grafana — ALB(Cognito 인증) 에서만 받는다. 대상 그룹 · 리스너 규칙은 monitoring/lgtm 스택이 만든다
resource "aws_vpc_security_group_ingress_rule" "obs_grafana_from_alb" {
  security_group_id            = aws_security_group.obs.id
  description                  = "Grafana from ALB (Cognito authenticated)"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "alb_to_obs_grafana" {
  security_group_id            = aws_security_group.alb.id
  description                  = "to Grafana on obs tasks"
  referenced_security_group_id = aws_security_group.obs.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

# 나가는 것은 둘이다.
#   443  — S3 (게이트웨이 엔드포인트: 저장소 · 설정 내려받기) · ECR · SSM(ECS Exec) · Secrets Manager · SNS (엔드포인트 또는 NAT)
#   3306 — NCP DB (mysqld_exporter). NAT 고정 IP 로 나가야 ACG 를 지난다. Public 도메인의 IP 가 고정되지 않아 0.0.0.0/0 이다
#          (migration.tf 와 같은 이유)
# VPC DNS · 시간 동기화 · IMDS 는 SG 가 거르지 않는다.
resource "aws_vpc_security_group_egress_rule" "obs_https" {
  security_group_id = aws_security_group.obs.id
  description       = "HTTPS to AWS APIs, S3 gateway endpoint, package and image registries, GitHub"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "obs_mysql" {
  security_group_id = aws_security_group.obs.id
  description       = "MySQL to NCP DB via NAT (mysqld_exporter)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
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

# ── obs 컨테이너 인스턴스 ───────────────────────────────────────
# obs 태스크를 올리는 EC2 (ecs 스택의 obs 용량 공급자). 태스크는 awsvpc 라 위 obs SG 를 따로 쓰고,
# 이 SG 는 인스턴스 자신(ECS 에이전트 · SSM · 이미지 pull · EBS 붙이기)의 것이다.
# 인바운드는 없다. 사람은 ECS Exec(태스크) 또는 Session Manager(인스턴스)로 들어온다.
resource "aws_security_group" "obs_instance" {
  name        = "${local.name_prefix}-obs-instance-sg"
  description = "Observability ECS container instance (no inbound)"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-obs-instance-sg" }
}

# ECS · SSM · EC2 API · 이미지 레지스트리 · S3 게이트웨이 엔드포인트. 대상 주소가 고정되지 않아 0.0.0.0/0 이다
resource "aws_vpc_security_group_egress_rule" "obs_instance_https" {
  security_group_id = aws_security_group.obs_instance.id
  description       = "HTTPS to ECS, SSM, EC2 API, image registries, S3 gateway endpoint"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_obs_instance" {
  security_group_id            = local.vpce_sg_id
  description                  = "from obs container instance (ECS agent, SSM agent, AWS APIs)"
  referenced_security_group_id = aws_security_group.obs_instance.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
