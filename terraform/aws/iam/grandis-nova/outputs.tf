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

output "github_mock_deploy_role_arn" {
  description = "mock 저장소 워크플로의 role-to-assume 에 넣는 값 (github_deploy_mock.tf)"
  value       = aws_iam_role.github_deploy_mock.arn
}

output "ecs_lb_role_arn" {
  description = "ECS Blue/Green 이 리스너 규칙 · 타깃 그룹을 바꿀 때 쓰는 역할"
  value       = aws_iam_role.ecs_lb.arn
}

output "scheduler_role_arn" {
  value = aws_iam_role.scheduler.arn
}

output "migration_execution_role_arn" {
  description = "마이그레이션 태스크(ecs 스택 migration.tf)의 실행 역할. db/migrator 시크릿을 읽는다"
  value       = aws_iam_role.migration_execution.arn
}

output "bastion_instance_profile" {
  value = aws_iam_instance_profile.bastion.name
}

output "obs_task_role_arn" {
  description = "관측 스택(monitoring) ECS 태스크 역할"
  value       = aws_iam_role.obs.arn
}

output "obs_instance_profile" {
  description = "obs 태스크를 올리는 ECS 컨테이너 인스턴스(ecs 스택의 obs 용량 공급자) 프로파일"
  value       = aws_iam_instance_profile.obs_instance.name
}

output "obs_execution_role_arn" {
  description = "관측 스택(monitoring) ECS 실행 역할. Grafana admin 비밀번호를 넣는다"
  value       = aws_iam_role.obs_execution.arn
}

output "service_permissions" {
  description = "서비스별 태스크 역할 권한 요약"
  value = {
    for k, v in local.services : k => {
      send_queues    = v.queues.send
      consume_queues = v.queues.consume
      dlq            = v.queues.dlq
      dlq_send       = v.queues.dlq_send
      uploads        = v.uploads
      upload_cleanup = v.upload_cleanup
    }
  }
}

