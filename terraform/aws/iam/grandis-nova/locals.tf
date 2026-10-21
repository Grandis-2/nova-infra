# 역할과 권한
#   실행 역할   (execution.tf)     ECS 에이전트가 이미지 Pull, 로그, 시크릿 조회에 쓴다
#   태스크 역할 (main.tf)          앱 코드가 AWS API 를 부를 때 쓴다. 서비스마다 필요한 권한만
#   배포 역할   (github_deploy.tf) GitHub Actions 가 OIDC 로 잠깐 받는다. mock 저장소는 github_deploy_mock.tf

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # ecs 스택 리소스의 ARN 을 이름 규칙으로 계산한다
  # (remote state 로 참조하면 iam <-> ecs 순환 의존이 생긴다)
  cluster_arn   = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${local.name_prefix}"
  task_def_arn  = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name_prefix}-*"
  log_group_arn = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${local.name_prefix}*"
  queues        = data.terraform_remote_state.sqs.outputs.queues
  sched_dlq_arn = data.terraform_remote_state.sqs.outputs.scheduler_dlq.arn
  upload_bucket = data.terraform_remote_state.s3.outputs.upload_bucket.arn
  # be 배포 역할이 push 하는 저장소. mock 저장소는 mock 전용 배포 역할(github_deploy_mock.tf)만 push 한다
  mock_ecr_repo_keys = ["mock", "mock-migration"]
  ecr_repo_arns      = [for k, arn in data.terraform_remote_state.ecr.outputs.repository_arns : arn if !contains(local.mock_ecr_repo_keys, k)]
  mock_ecr_repo_arns = [for k in local.mock_ecr_repo_keys : data.terraform_remote_state.ecr.outputs.repository_arns[k] if contains(keys(data.terraform_remote_state.ecr.outputs.repository_arns), k)]

  # ecr 출력에 아직 없는 서비스 · migration 저장소(github_deploy.tf 의 사전 조건)
  ecr_repo_keys_missing = sort(tolist(setsubtract(concat(keys(local.services), ["migration"]), keys(data.terraform_remote_state.ecr.outputs.repository_arns))))
}
