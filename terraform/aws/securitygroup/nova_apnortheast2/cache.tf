# Valkey. 서비스 → 캐시 인바운드는 서비스 모듈이 만든다 (service.yml 의 redis)
resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "ElastiCache Redis"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name_prefix}-redis-sg" }
}

# DB(RDS)의 SG 는 rds.tf 다.
