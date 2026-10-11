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
