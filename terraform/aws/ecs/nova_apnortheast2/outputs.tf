output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "CloudFront 오리진으로 쓴다"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  description = "CloudWatch 지표 차원에 쓴다"
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffixes" {
  description = "\"<서비스>-<순번>-<색>\" -> 타깃 그룹 ARN 접미사 (monitoring 의 경보 차원)"
  value = merge([
    for k, m in module.service : { for tk, sfx in m.target_group_arn_suffixes : "${k}-${tk}" => sfx }
  ]...)
}

output "service_names" {
  value = { for k, m in module.service : k => m.service_name if m.service_name != null }
}

output "task_definition_families" {
  value = { for k, m in module.service : k => m.task_definition_family }
}

output "batch_task_definition_arn" {
  description = "Scheduler 가 RunTask 로 띄울 태스크 정의"
  value       = try(module.service["batch"].task_definition_arn, "") # batch 가 deploy: false 면 빈 값
}

output "log_group_names" {
  value = { for k, m in module.service : k => m.log_group_name }
}

output "service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

output "service_discovery_namespace_arn" {
  description = "Service Connect 네임스페이스. monitoring 스택의 OTel 게이트웨이 · obs 서비스가 otel-gateway · pyroscope 등으로 자신을 내놓는다"
  value       = aws_service_discovery_private_dns_namespace.this.arn
}

output "service_discovery_namespace_name" {
  value = aws_service_discovery_private_dns_namespace.this.name
}

output "obs_capacity_provider_name" {
  description = "obs 서비스(monitoring 스택)가 쓰는 EC2 용량 공급자"
  value       = aws_ecs_capacity_provider.obs.name
}

output "obs_subnet_id" {
  description = "obs 인스턴스 · 태스크의 서브넷 (데이터 EBS 와 같은 AZ)"
  value       = data.aws_subnet.obs.id
}

output "obs_autoscaling_group_name" {
  value = aws_autoscaling_group.obs.name
}

output "obs_data_mount_path" {
  description = "obs 인스턴스의 데이터 EBS 마운트 경로. 아래 디렉터리를 컨테이너에 bind mount 한다"
  value       = local.obs_mount_path
}

output "obs_data_dirs" {
  description = "데이터 디렉터리 -> 소유자 uid:gid. 컨테이너 user 와 같아야 한다"
  value       = local.obs_data_dirs
}

output "origin_verify_header" {
  description = "edge 스택이 CloudFront 원본 요청에 붙이는 헤더"
  value = {
    name  = local.origin_verify_header
    value = random_password.origin_verify.result
  }
  sensitive = true
}

output "migration_task_definition_family" {
  description = "배포 전 마이그레이션 태스크 (migration.tf)"
  value       = aws_ecs_task_definition.migration.family
}

output "migration_run_task_parameter" {
  description = "be release 가 읽는 SSM 파라미터 이름 (클러스터 · 태스크 정의 · 서브넷 · SG · 로그)"
  value       = aws_ssm_parameter.migration.name
}

output "observability_cluster_name" {
  description = "관측 스택(obs · OTel 게이트웨이 · 브라우저 수집기)을 올리는 클러스터"
  value       = aws_ecs_cluster.observability.name
}

output "observability_cluster_arn" {
  value = aws_ecs_cluster.observability.arn
}

output "alb_https_listener_arn" {
  description = "메인 ALB 의 HTTPS 리스너. 다른 저장소(atlantis-deploy)가 자기 서비스의 규칙 · SNI 인증서를 이 리스너에 붙인다"
  value       = try(aws_lb_listener.https[0].arn, "")
}

output "proxysql" {
  description = "RDS 이전 기간의 ProxySQL (proxysql_enabled 일 때만). 런북은 같은 값을 SSM /<접두사>/db-migration/proxysql 에서 읽는다"
  value = var.proxysql_enabled ? {
    nlb_address      = aws_lb.proxysql[0].dns_name
    service_name     = aws_ecs_service.proxysql[0].name
    target_group_arn = aws_lb_target_group.proxysql[0].arn
    parameter_name   = aws_ssm_parameter.proxysql[0].name
  } : null
}
