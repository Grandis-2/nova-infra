# 마이그레이션 태스크 실행 역할 — release 가 서비스 배포 전에 RunTask 로 띄우는 Flyway 태스크 (ecs 스택 migration.tf)
# 서비스 공용 실행 역할(execution.tf)은 db/migrator 시크릿을 읽지 못하게 막아 두었으므로 따로 둔다.
# 태스크 역할은 두지 않는다 — Flyway 는 AWS API 를 부르지 않는다.
locals {
  migration_task_def_arn = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name_prefix}-migration:*"
  migration_param_arn    = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/migration/run-task"
  migration_log_arn      = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${local.name_prefix}-migration:log-stream:*"

  # mock 마이그레이션(external_mock). 실행 역할은 위 역할을 같이 쓴다 — 같은 db/migrator 계정이다
  mock_migration_task_def_arn = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name_prefix}-mock-migration:*"
  mock_migration_param_arn    = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/mock-migration/run-task"
  mock_migration_log_arn      = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${local.name_prefix}-mock-migration:log-stream:*"
}

resource "aws_iam_role" "migration_execution" {
  name               = "${local.name_prefix}-migration-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "migration_execution_managed" {
  role       = aws_iam_role.migration_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS 에이전트가 마이그레이션 계정을 컨테이너 환경변수로 넣는다. ARN 끝의 6자리는 Secrets Manager 가 붙인다
resource "aws_iam_role_policy" "migration_execution_secret" {
  name = "read-migrator-secret"
  role = aws_iam_role.migration_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MigratorSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/db/migrator-??????"]
      },
    ]
  })
}
