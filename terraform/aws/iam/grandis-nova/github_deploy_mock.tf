# mock 전용 배포 역할 (GitHub Actions · OIDC, NV-524)
# mock 저장소 release 가 자기 이미지(nova/mock · nova/mock-migration)를 올리고, mock 마이그레이션을 돌리고, mock 서비스를 배포한다.
# be 배포 역할(github_deploy.tf)을 같이 쓰면 mock 워크플로가 모든 nova/* 이미지 · 서비스에 손댈 수 있어 따로 두고 mock 것만 준다.
# OIDC 공급자와 허용 브랜치(github_deploy_branches)는 be 역할과 같다.

locals {
  mock_service_arn = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.name_prefix}/${local.name_prefix}-mock"

  github_mock_subjects = flatten([
    for repo in var.github_mock_repositories : [
      for ref in var.github_deploy_branches : "repo:${repo}:ref:${ref}"
    ]
  ])
}

data "aws_iam_policy_document" "github_assume_mock" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # mock 저장소의 main 브랜치 워크플로만
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_mock_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy_mock" {
  name                 = "${local.name_prefix}-github-deploy-mock"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_mock.json
  max_session_duration = 3600

  lifecycle {
    # 빈 목록이면 신뢰 정책의 sub 조건이 비어 아무도 받지 못하는 역할이 된다
    precondition {
      condition     = length(var.github_mock_repositories) > 0
      error_message = "github_mock_repositories 가 비어 있습니다. mock 저장소의 OIDC sub(owner@id/repo@id)를 terraform.tfvars 에 넣으세요."
    }
  }
}

resource "aws_iam_role_policy" "github_deploy_mock" {
  name = "deploy"
  role = aws_iam_role.github_deploy_mock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = local.mock_ecr_repo_arns
      },
      {
        Sid      = "DeployService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = [local.mock_service_arn]
      },
      {
        # ListTasks · DescribeTasks 는 서비스 리소스로 좁힐 수 없어 클러스터 조건으로 건다 (조회만)
        Sid      = "WatchTasks"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks", "ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        Sid    = "WatchDeployments"
        Effect = "Allow"
        Action = ["ecs:ListServiceDeployments", "ecs:DescribeServiceDeployments", "ecs:DescribeServiceRevisions"]
        Resource = [
          local.mock_service_arn,
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-deployment/${local.name_prefix}/${local.name_prefix}-mock/*",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-revision/${local.name_prefix}/${local.name_prefix}-mock/*",
        ]
      },
      {
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters"]
        Resource = [local.cluster_arn]
      },
      # ── 배포 전 마이그레이션 (ecs 스택 migration.tf 의 mock_migration) ──
      {
        Sid      = "RunMigration"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.mock_migration_task_def_arn]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        # mock 마이그레이션도 be 것과 같은 실행 역할(db/migrator)을 쓴다
        Sid      = "PassMigrationRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.migration_execution.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        Sid      = "ReadMigrationTarget"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.mock_migration_param_arn]
      },
      {
        Sid      = "ReadMigrationLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [local.mock_migration_log_arn]
      },
    ]
  })

  # 저장소가 빠진 채 적용하면 mock release 가 이미지를 올리지 못한다. ecr 을 apply 하기 전에 만든 plan 은 막는다
  lifecycle {
    precondition {
      condition     = length(local.mock_ecr_repo_arns) == length(local.mock_ecr_repo_keys)
      error_message = "ecr 스택에 mock · mock-migration 저장소가 아직 없습니다. ecr 을 apply 한 뒤 iam 을 다시 plan 하세요."
    }
  }
}
