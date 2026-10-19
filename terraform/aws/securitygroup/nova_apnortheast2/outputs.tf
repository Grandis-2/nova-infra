output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_ids" {
  description = "서비스 키(member, catalog, preorder, order, waitingroom, worker, batch, mock) -> SG ID"
  value       = { for k, m in module.service : k => m.security_group_id }
}

output "redis_security_group_id" {
  value = aws_security_group.redis.id
}

output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}

output "alb_origin_port" {
  description = "CloudFront 가 ALB 에 붙는 포트. edge 스택이 자기 설정과 비교한다"
  value       = local.alb_origin_port
}

output "service_access" {
  description = "서비스별 인바운드 요약 — 누가 이 서비스에 들어올 수 있나"
  value = {
    for k, v in local.services : k => {
      from_alb      = length(v.routes) > 0 ? distinct([v.port, v.health.port]) : []
      from_services = sort([for c in values(local.service_calls) : c.caller if c.callee == k])
      uses_cache    = v.redis != null
    }
  }
}

output "obs_security_group_id" {
  description = "관측 스택(obs) 태스크 SG. 게이트웨이 SG 에서 3100 · 14317 · 9009, 프로파일을 켠 서비스 SG 에서 4041, ALB 에서 3000(Grafana) 만 받는다"
  value       = aws_security_group.obs.id
}

output "migration_security_group_id" {
  description = "마이그레이션 태스크 SG. 인바운드 없음, 3306 · 443 만 나간다"
  value       = aws_security_group.migration.id
}

output "obs_instance_security_group_id" {
  description = "obs 태스크를 올리는 ECS 컨테이너 인스턴스 SG. 인바운드 없음, 443 만 나간다"
  value       = aws_security_group.obs_instance.id
}

output "otel_gateway_security_group_id" {
  description = "OTel 게이트웨이(NV-543) 태스크 SG. 서비스 SG 에서 4317 · 4318 을 받고 obs 의 Loki · Tempo · Mimir 로 보낸다"
  value       = aws_security_group.otel_gateway.id
}

output "edge_logs_security_group_id" {
  description = "엣지 로그 Lambda(NV-542) SG. 게이트웨이 4318 과 443 으로만 나간다"
  value       = aws_security_group.edge_logs.id
}

output "rum_collector_security_group_id" {
  description = "브라우저 수집기 태스크 SG. ALB 에서 12347 · 13133 을 받고 게이트웨이 4318 로 보낸다"
  value       = aws_security_group.rum_collector.id
}
