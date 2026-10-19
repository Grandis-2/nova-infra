# 부하 시험(Grandis-2/nova-loadtest) 역할. 태스크는 ecs 스택의 nova-prod-loadtest 클러스터에서 RunTask 로만 뜬다.
#
#   GitHub (OIDC)
#     -loadtest-github-run    시험 실행. environment loadtest(승인자, main 만) 작업만 받는다. 컨트롤러를 띄우고 결과를 읽는다
#     -loadtest-github-build  이미지 빌드. main 브랜치만. 시험 저장소 셋에 push, 도는 태스크 확인 · 중지
#   태스크 역할
#     -loadtest-controller    k6 · 발급기를 띄우고 멈춘다. Mimir 조회용으로 obs 태스크 IP 를 찾는다. 결과를 모아 쓴다
#     -loadtest-k6            토큰 읽기, 자기 요약(results/*/k6-*.json) 쓰기
#     -loadtest-minter        토큰 쓰기
#   실행 역할
#     -loadtest-execution         컨트롤러 · k6. 이미지 · 로그 · 부하 시험 헤더
#     -loadtest-minter-execution  발급기. 이미지 · 로그 · member 서명키
#
# 서비스 공용 실행 역할(execution.tf)은 쓰지 않는다. 그 역할은 서비스 비밀 전부(서명키 · DB 비밀번호 포함)를 읽고, 헤더(ops/*)는 못 읽는다.
# 시험 쪽이 앱 역할을 넘기게 되면 앱과 시험의 권한 경계도 흐려진다.
# 시험 데이터 준비 · 정리 태스크의 역할(-loadtest-data, -loadtest-data-execution)은 DB 계정을 정한 뒤 더한다.

locals {
  loadtest_name        = "${local.name_prefix}-loadtest"
  loadtest_cluster_arn = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${local.loadtest_name}"
  obs_cluster_arn      = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${local.name_prefix}-observability"

  # 작업 정의 패밀리 (ecs 스택 loadtest.tf)
  loadtest_task_def_arn = {
    for f in ["controller", "k6", "token-minter"] :
    f => "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.loadtest_name}-${f}:*"
  }

  loadtest_bucket_arn = data.terraform_remote_state.s3.outputs.loadtest_bucket.arn
  loadtest_header_arn = data.terraform_remote_state.secretsmanager.outputs.loadtest_header_secret.arn
  jwt_private_key_arn = data.terraform_remote_state.secretsmanager.outputs.generated_secret_arns["member/JWT_PRIVATEKEY"]
  loadtest_ecr_arns   = [for k, arn in data.terraform_remote_state.ecr.outputs.repository_arns : arn if startswith(k, "loadtest-")]

  loadtest_param_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/loadtest/*"
  # 로그 그룹 하나에 스트림 접두사가 컨테이너 이름이다. Actions 로그로 옮기는 것은 컨트롤러 로그뿐이다
  loadtest_controller_log_arn = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${local.loadtest_name}:log-stream:controller/*"

  # 정리 전에 비었는지 보는 큐 (컨트롤러)
  loadtest_watched_queues = ["preorder-register", "preorder-cancel", "preorder-events", "order-events"]

  github_loadtest_repo = "Grandis-2@336932992/nova-loadtest@1423176487" # OIDC sub 의 repo: 뒤 (gh api repos/Grandis-2/nova-loadtest/actions/oidc/customization/sub)
}

# ── GitHub 역할 ─────────────────────────────────────────────
# 둘로 나눈다. 하나로 두면 main 조건으로 맡는 빌드 같은 워크플로도 컨트롤러를 띄울 수 있어, environment 승인 없이 운영에 부하를 보내는 길이 생긴다.
# 작업이 environment 를 쓰면 sub 가 브랜치 대신 environment 가 된다. main 에서만 돌게 하는 것은 environment 의 배포 브랜치 규칙이 맡는다.
data "aws_iam_policy_document" "loadtest_github_assume" {
  for_each = {
    run   = "environment:loadtest"
    build = "ref:refs/heads/main"
  }

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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_loadtest_repo}:${each.value}"]
    }
  }
}

# 세션은 기본 1시간. 긴 시험은 워크플로가 50분마다 OIDC 토큰을 다시 받아 세션을 바꾼다
resource "aws_iam_role" "loadtest_github" {
  for_each = data.aws_iam_policy_document.loadtest_github_assume

  name                 = "${local.loadtest_name}-github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "loadtest_github_run" {
  name = "run-load-test"
  role = aws_iam_role.loadtest_github["run"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunController"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.loadtest_task_def_arn["controller"]]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.loadtest_cluster_arn }
        }
      },
      {
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.loadtest_cluster_arn }
        }
      },
      {
        # RunTask 는 작업 정의의 태스크 역할과 실행 역할을 모두 넘겨야 한다
        Sid      = "PassControllerRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.loadtest_task["controller"].arn, aws_iam_role.loadtest_execution["execution"].arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # 실행 파라미터 둘(run-task · observability). 컨트롤러에 환경 변수로 넘긴다
        Sid      = "ReadRunParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.loadtest_param_arn]
      },
      {
        Sid      = "ListResultsAndTokens"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.loadtest_bucket_arn]
        Condition = {
          StringLike = { "s3:prefix" = ["results/*", "tokens/*"] }
        }
      },
      {
        Sid      = "ReadResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.loadtest_bucket_arn}/results/*"]
      },
      {
        # 컨트롤러가 죽었을 때의 뒷정리
        Sid      = "DeleteTokens"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${local.loadtest_bucket_arn}/tokens/*"]
      },
      {
        # FilterLogEvents 는 로그 그룹 단위라 스트림으로 좁힐 수 없어 주지 않는다
        Sid      = "ReadControllerLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [local.loadtest_controller_log_arn]
      },
    ]
  })
}

resource "aws_iam_role_policy" "loadtest_github_build" {
  name = "build-images"
  role = aws_iam_role.loadtest_github["build"].id

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
        Resource = local.loadtest_ecr_arns
      },
      {
        # latest 를 옮기기 전에 도는 시험이 없는지 본다. 멈추는 워크플로(stop.yml)도 이 역할을 쓴다
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.loadtest_cluster_arn }
        }
      },
    ]
  })

  # ecr 을 apply 하기 전에 만든 plan 이면 시험 저장소가 빠진 채 들어간다
  lifecycle {
    precondition {
      condition     = length(local.loadtest_ecr_arns) == 3
      error_message = "ecr 스택에 loadtest-* 저장소 셋이 아직 없습니다. ecr 을 apply 한 뒤 iam 을 다시 plan 하세요."
    }
  }
}

# ── 태스크 역할 ─────────────────────────────────────────────
resource "aws_iam_role" "loadtest_task" {
  for_each = toset(["controller", "k6", "minter"])

  name               = "${local.loadtest_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "loadtest_controller" {
  name = "run-and-judge"
  role = aws_iam_role.loadtest_task["controller"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunRunnersAndMinter"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.loadtest_task_def_arn["k6"], local.loadtest_task_def_arn["token-minter"]]
        Condition = {
          ArnEquals = { "ecs:cluster" = local.loadtest_cluster_arn }
        }
      },
      {
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.loadtest_cluster_arn }
        }
      },
      {
        # Mimir 는 Cloud Map 에 없어 obs 태스크의 IP 를 찾아 붙는다
        Sid      = "FindObsTask"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks", "ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.obs_cluster_arn }
        }
      },
      {
        Sid    = "PassRunnerRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.loadtest_task["k6"].arn,
          aws_iam_role.loadtest_task["minter"].arn,
          aws_iam_role.loadtest_execution["execution"].arn,
          aws_iam_role.loadtest_execution["minter-execution"].arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # Container Insights 의 실행기 CPU. 리소스 수준 제한이 없는 동작이다
        Sid      = "ReadRunnerCpu"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        # 정리 전에 큐가 비었는지 본다
        Sid      = "ReadQueueDepth"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = [for q in local.loadtest_watched_queues : local.queues[q].arn]
      },
      {
        Sid      = "ListResultsAndTokens"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.loadtest_bucket_arn]
        Condition = {
          StringLike = { "s3:prefix" = ["results/*", "tokens/*"] }
        }
      },
      {
        # 태스크별 k6 요약을 모아 plan · summary 를 쓴다
        Sid      = "ReadWriteResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${local.loadtest_bucket_arn}/results/*"]
      },
      {
        Sid      = "DeleteTokens"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${local.loadtest_bucket_arn}/tokens/*"]
      },
    ]
  })
}

# 시험 ID 는 실행할 때 정해져 IAM 으로 특정 시험까지 좁힐 수 없다. 대신 파일 이름 꼴로 좁히고 읽기 · 지우기를 주지 않아,
# 컨트롤러가 쓰는 summary 나 다른 태스크의 요약을 고칠 수 없게 한다
resource "aws_iam_role_policy" "loadtest_k6" {
  name = "tokens-and-summary"
  role = aws_iam_role.loadtest_task["k6"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTokens"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.loadtest_bucket_arn}/tokens/*"]
      },
      {
        Sid      = "WriteOwnSummary"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${local.loadtest_bucket_arn}/results/*/k6-*.json"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "loadtest_minter" {
  name = "write-tokens"
  role = aws_iam_role.loadtest_task["minter"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteTokens"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${local.loadtest_bucket_arn}/tokens/*"]
      },
    ]
  })
}

# ── 실행 역할 ─────────────────────────────────────────────
# 서명키는 공용 실행 역할(모든 앱 서비스)과 -loadtest-minter-execution 만 읽는다. 새로 느는 주체는 발급기 하나다
locals {
  loadtest_execution_secrets = {
    execution        = local.loadtest_header_arn # 컨트롤러 · k6
    minter-execution = local.jwt_private_key_arn # 발급기
  }
}

resource "aws_iam_role" "loadtest_execution" {
  for_each = local.loadtest_execution_secrets

  name               = "${local.loadtest_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "loadtest_execution_managed" {
  for_each = aws_iam_role.loadtest_execution

  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "loadtest_execution_secret" {
  for_each = aws_iam_role.loadtest_execution

  name = "read-secret"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.loadtest_execution_secrets[each.key]]
      },
    ]
  })
}
