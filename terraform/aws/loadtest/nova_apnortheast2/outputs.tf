output "cluster_name" {
  value = aws_ecs_cluster.loadtest.name
}

output "bucket" {
  value = aws_s3_bucket.loadtest.id
}

output "role_arns" {
  description = "github-run · github-build 는 nova-loadtest 워크플로가 맡는다(저장소 변수에 넣는다)"
  value = merge(
    { for k, r in aws_iam_role.github : "github-${k}" => r.arn },
    { for k, r in aws_iam_role.task : k => r.arn },
    { for k, r in aws_iam_role.execution : k => r.arn },
  )
}

output "repository_urls" {
  value = { for k, r in aws_ecr_repository.loadtest : k => r.repository_url }
}

output "run_parameters" {
  description = "nova-loadtest 워크플로가 읽는 SSM 파라미터"
  value       = [aws_ssm_parameter.run_task.name, aws_ssm_parameter.observability.name]
}
