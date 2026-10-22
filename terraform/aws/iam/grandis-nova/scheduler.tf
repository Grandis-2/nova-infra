# EventBridge Scheduler (단발 배치 실행 주체) — scheduler 스택이 service.yml 의 schedule 마다 RunTask 로 띄운다
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler-execution"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "run-batch-task"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTask"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.task_def_arn]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        # propagate_tags 로 태스크에 태그를 붙이려면 필요하다
        Sid      = "TagOnRunTask"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "*"
        Condition = {
          StringEquals = { "ecs:CreateAction" = "RunTask" }
        }
      },
      {
        Sid    = "PassRolesToTask"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        # service.yml 에 schedule 이 있는 앱의 태스크 역할만
        Resource = concat([aws_iam_role.task_execution.arn], [for k in keys(local.scheduled_services) : module.task_role[k].role_arn])
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        Sid      = "SendToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [local.sched_dlq_arn]
      },
    ]
  })
}
