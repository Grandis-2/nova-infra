# 배포 역할 (GitHub Actions · OIDC)
# 장기 액세스 키를 저장하지 않는다. 워크플로가 실행될 때만 토큰을 교환해 역할을 빌린다.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${local.name_prefix}-github-oidc" }
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # repo:owner/repo:ref:refs/heads/main 형태로 제한한다.
  github_subjects = flatten([
    for repo in var.github_repositories : [
      for ref in var.github_deploy_branches : "repo:${repo}:ref:${ref}"
    ]
  ])
}

data "aws_iam_policy_document" "github_assume" {
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

    # 우리 저장소의 main 브랜치 워크플로만 이 역할을 쓸 수 있다
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name_prefix}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "deploy"
  role = aws_iam_role.github_deploy.id

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
        Resource = local.ecr_repo_arns
      },
      {
        Sid      = "DeployService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        # 관측 서비스는 같은 클러스터에 있지만 앱 배포가 건드리면 안 된다. 게이트웨이가 다시 뜨면 메모리 큐가 사라진다.
        # 이름 규칙이 앱과 같아(nova-prod-*) 허용 목록으로 가르지 않고 여기서 막는다
        Sid    = "KeepObservabilityServices"
        Effect = "Deny"
        Action = "ecs:UpdateService"
        Resource = [
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.name_prefix}/${local.name_prefix}-obs",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.name_prefix}/${local.name_prefix}-otel-gateway",
        ]
      },
      {
        # DescribeClusters 는 ecs:cluster 조건 키를 지원하지 않아 리소스로 제한한다
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters"]
        Resource = [local.cluster_arn]
      },
      {
        # Blue/Green 진행 상황 조회. 배포는 force-new-deployment 뿐이고
        # 태스크 정의는 Terraform 이 관리하므로 RegisterTaskDefinition 은 주지 않는다
        Sid    = "WatchDeployments"
        Effect = "Allow"
        Action = ["ecs:ListServiceDeployments", "ecs:DescribeServiceDeployments", "ecs:DescribeServiceRevisions"]
        Resource = [
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.name_prefix}/*",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-deployment/${local.name_prefix}/*",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-revision/${local.name_prefix}/*",
        ]
      },
      # ── 배포 전 마이그레이션 (migration.tf, be .github/scripts/ecs-migrate.sh) ──
      # DB(NCP)는 NAT 고정 IP 만 받아 러너에서는 닿지 않는다. 그래서 클러스터 안에 Flyway 태스크를 띄우고 끝나기를 기다린다
      {
        Sid      = "RunMigration"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.migration_task_def_arn]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        # RunTask 는 태스크 정의의 역할을 넘겨야 한다. 마이그레이션 실행 역할만 넘길 수 있다
        Sid      = "PassMigrationRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.migration_execution.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # 띄울 태스크 정의 · 서브넷 · SG (ecs 스택이 적는다)
        Sid      = "ReadMigrationTarget"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.migration_param_arn]
      },
      {
        # Flyway 출력을 워크플로 로그로 옮긴다
        Sid      = "ReadMigrationLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [local.migration_log_arn]
      },
    ]
  })

  # EcrPush 는 ecr 스택의 저장소 목록으로 건다. ecr 을 apply 하기 전에 만든 plan 을 적용하면 nova/migration 이 빠진 채
  # 들어가고, release 는 마이그레이션 이미지를 올리지 못해 아무것도 배포하지 못한다. 그런 plan 은 여기서 막는다
  lifecycle {
    precondition {
      condition     = contains(keys(data.terraform_remote_state.ecr.outputs.repository_arns), "migration")
      error_message = "ecr 스택에 migration 저장소가 아직 없습니다. ecr 을 apply 한 뒤 iam 을 다시 plan 하세요."
    }
  }
}
