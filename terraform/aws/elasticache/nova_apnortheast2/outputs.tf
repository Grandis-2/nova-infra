# 클러스터 모드가 꺼져 있으면 primary/reader, 켜져 있으면 configuration 엔드포인트만 값이 있다
output "redis_endpoints" {
  description = "클러스터 키 -> 쓰기 엔드포인트"
  value = {
    for k, rg in aws_elasticache_replication_group.this : k => try(coalesce(
      rg.primary_endpoint_address,
      rg.configuration_endpoint_address,
    ), "")
  }
}

output "redis_reader_endpoints" {
  description = "클러스터 키 -> 읽기 엔드포인트"
  value = {
    for k, rg in aws_elasticache_replication_group.this : k => try(coalesce(
      rg.reader_endpoint_address,
      rg.configuration_endpoint_address,
    ), "")
  }
}

output "redis_ports" {
  description = "클러스터 키 -> 포트"
  value       = { for k, rg in aws_elasticache_replication_group.this : k => rg.port }
}
