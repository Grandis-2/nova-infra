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

output "origin_verify_header" {
  description = "edge 스택이 CloudFront 원본 요청에 붙이는 헤더"
  value = {
    name  = local.origin_verify_header
    value = random_password.origin_verify.result
  }
  sensitive = true
}
