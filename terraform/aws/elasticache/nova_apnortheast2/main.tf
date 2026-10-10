# Valkey (대기열, 게이트웨이 제어 평면). Redis 프로토콜 호환이라 앱 코드는 그대로 쓰고,
# 같은 노드 타입 기준 Redis 보다 20% 싸다.
#
# 비용 때문에 단일 노드 클러스터 하나를 모든 서비스가 같이 쓴다.
# 재시작·점검 중에는 잠깐 끊기고, 데이터는 마지막 스냅샷으로 돌아간다.
# 대기열 부하가 다른 서비스에 영향을 주면 clusters 에 waitingroom 을 추가하고
# application/waitingroom/service.yml 의 redis 를 "waitingroom" 으로 바꾼다.

locals {
  db_subnet_ids = data.terraform_remote_state.vpc.outputs.db_subnet_ids
  redis_sg_id   = data.terraform_remote_state.security.outputs.redis_security_group_id

  # 9.1 -> valkey9
  family = "valkey${split(".", var.engine_version)[0]}"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-cache-subnet-group"
  subnet_ids = local.db_subnet_ids
}

resource "aws_elasticache_parameter_group" "this" {
  # 메이저 버전을 올릴 때 이름이 겹치지 않도록 family 를 넣는다
  name   = "${local.name_prefix}-${local.family}"
  family = local.family

  # 메모리가 차면 TTL 이 있는 키 중 오래 안 쓴 것부터 지운다.
  # 대기열 항목에는 TTL 이 있어 이쪽이 먼저 정리된다.
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # 키 -> 복제 그룹 ID
  clusters = {
    main = "${local.name_prefix}-valkey"
  }
}

resource "aws_cloudwatch_log_group" "slow" {
  for_each = local.clusters

  name              = "/aws/elasticache/${each.value}/slow-log"
  retention_in_days = 7
}

resource "aws_elasticache_replication_group" "this" {
  for_each = local.clusters

  replication_group_id = each.value
  description          = "Valkey for ${each.key}"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379 # 보안 그룹(securitygroup 스택)도 6379 만 연다

  # multi_az 면 primary + replica 로 자동 장애조치
  num_cache_clusters         = var.multi_az ? 2 : 1
  automatic_failover_enabled = var.multi_az
  multi_az_enabled           = var.multi_az

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [local.redis_sg_id]
  parameter_group_name = aws_elasticache_parameter_group.this.name

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  # AUTH 토큰 없이 VPC 와 SG 로만 접근을 제한한다

  snapshot_retention_limit = var.snapshot_retention_days
  snapshot_window          = "17:00-18:00" # UTC, KST 02:00
  maintenance_window       = "mon:19:00-mon:20:00"

  auto_minor_version_upgrade = true
  apply_immediately          = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.slow[each.key].name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  tags = { Name = each.value }
}
