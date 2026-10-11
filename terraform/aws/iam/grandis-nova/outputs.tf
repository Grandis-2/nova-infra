output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "task_role_arns" {
  description = "서비스 키 -> 태스크 역할 ARN"
  value       = { for k, m in module.task_role : k => m.role_arn }
}

output "github_deploy_role_arn" {
  description = "GitHub Actions 워크플로의 role-to-assume 에 넣는 값"
  value       = aws_iam_role.github_deploy.arn
}

output "ecs_lb_role_arn" {
  description = "ECS Blue/Green 이 리스너 규칙 · 타깃 그룹을 바꿀 때 쓰는 역할"
  value       = aws_iam_role.ecs_lb.arn
}

output "scheduler_role_arn" {
  value = aws_iam_role.scheduler.arn
}

output "bastion_instance_profile" {
  value = aws_iam_instance_profile.bastion.name
}

output "service_permissions" {
  description = "서비스별 태스크 역할 권한 요약"
  value = {
    for k, v in local.services : k => {
      send_queues    = v.queues.send
      consume_queues = v.queues.consume
      dlq            = v.queues.dlq
      uploads        = v.uploads
    }
  }
}
