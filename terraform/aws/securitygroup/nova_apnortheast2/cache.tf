# Valkey. 서비스 → 캐시 인바운드는 서비스 모듈이 만든다 (service.yml 의 redis)
resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "ElastiCache Redis"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-redis-sg" }
}

# DB 는 VPC 밖(NCP)에 있다. 서비스는 아웃바운드로 NAT 를 거쳐 나가고,
# 접근 제한은 NCP ACG(NAT 고정 IP 만 허용)가 맡는다.
