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
        # DescribeClusters 는 ecs:cluster 조건 키를 지원하지 않아 리소스로 제한한다
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters"]
        Resource = [local.cluster_arn]
      },
      {
        # Blue/Green 진행 상황 조회. 배포는 force-new-deployment 뿐이고
        # 태스크 정의는 Terraform 이 관리하므로 RegisterTaskDefinition · PassRole 은 주지 않는다
        Sid    = "WatchDeployments"
        Effect = "Allow"
        Action = ["ecs:ListServiceDeployments", "ecs:DescribeServiceDeployments", "ecs:DescribeServiceRevisions"]
        Resource = [
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.name_prefix}/*",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-deployment/${local.name_prefix}/*",
          "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service-revision/${local.name_prefix}/*",
        ]
      },
    ]
  })
}
