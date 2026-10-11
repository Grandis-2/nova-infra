# 실행 역할 (모든 서비스 공용)
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # 다른 계정이 이 역할을 빌려 쓰지 못하게 막는다
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS 에이전트가 컨테이너 환경변수로 넣을 시크릿을 읽는다.
# 서비스 DB 계정과 앱 시크릿만 허용하고, DB 마스터 계정 시크릿은 제외한다.
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "read-secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ServiceSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        # 이름 패턴으로 준다 — 서비스 비밀이 새로 생겨도 iam 을 다시 apply 할 필요가 없다.
        # db/admin · db/migrator · ops/* (사람용) 은 패턴에 걸리지 않는다
        Resource = [for p in ["app", "shared", "db/app"] : "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/${p}/*"]
      },
    ]
  })
}
