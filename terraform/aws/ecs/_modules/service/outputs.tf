output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  value = aws_ecs_task_definition.this.family
}

output "service_name" {
  value = var.create_service ? aws_ecs_service.this[0].name : null
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "target_group_arn_suffixes" {
  description = "\"<순번>-<색>\" -> 타깃 그룹 ARN 접미사 (지표 차원)"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn_suffix }
}

output "target_group_arns" {
  description = "\"<순번>-<색>\" -> 타깃 그룹 ARN (서비스 밖에서 규칙을 더 걸 때)"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "scaling_limit" {
  description = "오토스케일링 상한과 순간 폭주 증설의 CPU 기준(%). 오토스케일링이 없으면 null. monitoring 의 증설 한계 경보가 쓴다"
  value       = var.create_service && var.max_capacity > 0 ? { max = var.max_capacity, cpu = var.burst_cpu } : null
}
