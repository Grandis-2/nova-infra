# 역할
#   GitHub (OIDC)
#     -github-run    시험 실행. environment loadtest(승인자, main 만) 작업만 받는다. 컨트롤러를 띄우고 결과를 읽는다
#     -github-build  이미지 빌드. main 브랜치만. 시험 저장소 셋에 push, 도는 태스크 확인 · 중지
#   태스크 역할
#     -controller    k6 · 발급기를 띄우고 멈춘다. Mimir 조회용으로 obs 태스크 IP 를 찾는다. 결과를 모아 쓴다
#     -k6            토큰 읽기, 자기 요약(results/*/k6-*.json) 쓰기
#     -minter        토큰 쓰기
#   실행 역할
#     -execution         컨트롤러 · k6. 이미지 · 로그 · 부하 시험 헤더
#     -minter-execution  발급기. 이미지 · 로그 · member 서명키
#
# 서비스 공용 실행 역할(iam 스택 execution.tf)은 쓰지 않는다. 그 역할은 서비스 비밀 전부(서명키 · DB 비밀번호 포함)를 읽고, 헤더(ops/*)는 못 읽는다.
# 시험 쪽이 앱 역할을 넘기게 되면 앱과 시험의 권한 경계도 흐려진다.
# 시험 데이터 준비 · 정리 태스크의 역할(-data, -data-execution)은 DB 계정을 정한 뒤 더한다.

locals {
  # 작업 정의 패밀리의 모든 개정판. RunTask 는 패밀리 이름으로 최신 개정판을 띄운다
  task_def_arn = {
    for k, t in local.tasks :
    k => "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.loadtest_name}-${t.container}:*"
  }
  obs_cluster_arn = data.terraform_remote_state.ecs.outputs.observability_cluster_arn

  header_secret_arn   = data.terraform_remote_state.secrets.outputs.loadtest_header_secret.arn
  jwt_private_key_arn = data.terraform_remote_state.secrets.outputs.generated_secret_arns["member/JWT_PRIVATEKEY"]

  param_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/loadtest/*"
  # 로그 그룹 하나에 스트림 접두사가 컨테이너 이름이다. Actions 로그로 옮기는 것은 컨트롤러 로그뿐이다
  controller_log_arn = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:${aws_cloudwatch_log_group.loadtest.name}:log-stream:controller/*"

  # 정리 전에 비었는지 보는 큐 (컨트롤러)
  watched_queues = ["preorder-register", "preorder-cancel", "preorder-events", "order-events"]

  # OIDC sub 의 repo: 뒤. immutable subject 라 owner@id/repo@id (gh api repos/Grandis-2/nova-loadtest/actions/oidc/customization/sub)
  github_repo = "Grandis-2@336932992/nova-loadtest@1423176487"
}

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

# ── GitHub 역할 ─────────────────────────────────────────────
# 둘로 나눈다. 하나로 두면 main 조건으로 맡는 빌드 같은 워크플로도 컨트롤러를 띄울 수 있어, environment 승인 없이 운영에 부하를 보내는 길이 생긴다.
# 작업이 environment 를 쓰면 sub 가 브랜치 대신 environment 가 된다. main 에서만 돌게 하는 것은 environment 의 배포 브랜치 규칙이 맡는다.
data "aws_iam_policy_document" "github_assume" {
  for_each = {
    run   = "environment:loadtest"
    build = "ref:refs/heads/main"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo}:${each.value}"]
    }
  }
}

# 세션은 기본 1시간. 긴 시험은 워크플로가 50분마다 OIDC 토큰을 다시 받아 세션을 바꾼다
resource "aws_iam_role" "github" {
  for_each = data.aws_iam_policy_document.github_assume

  name                 = "${local.loadtest_name}-github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_run" {
  name = "run-load-test"
  role = aws_iam_role.github["run"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunController"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.task_def_arn["controller"]]
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.loadtest.arn }
        }
      },
      {
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.loadtest.arn }
        }
      },
      {
        # RunTask 는 작업 정의의 태스크 역할과 실행 역할을 모두 넘겨야 한다
        Sid      = "PassControllerRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.task["controller"].arn, aws_iam_role.execution["execution"].arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        # 실행 파라미터 둘(run-task · observability). 컨트롤러에 환경 변수로 넘긴다
        Sid      = "ReadRunParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [local.param_arn]
      },
      {
        Sid      = "ListResultsAndTokens"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.loadtest.arn]
        Condition = {
          StringLike = { "s3:prefix" = ["results/*", "tokens/*"] }
        }
      },
      {
        Sid      = "ReadResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/results/*"]
      },
      {
        # 컨트롤러가 죽었을 때의 뒷정리
        Sid      = "DeleteTokens"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/tokens/*"]
      },
      {
        # FilterLogEvents 는 로그 그룹 단위라 스트림으로 좁힐 수 없어 주지 않는다
        Sid      = "ReadControllerLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [local.controller_log_arn]
      },
    ]
  })
}

resource "aws_iam_role_policy" "github_build" {
  name = "build-images"
  role = aws_iam_role.github["build"].id

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
        Resource = [for r in aws_ecr_repository.loadtest : r.arn]
      },
      {
        # latest 를 옮기기 전에 도는 시험이 없는지 본다. 멈추는 워크플로(stop.yml)도 이 역할을 쓴다
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.loadtest.arn }
        }
      },
    ]
  })
}

# ── 태스크 역할 ─────────────────────────────────────────────
resource "aws_iam_role" "task" {
  for_each = toset(["controller", "k6", "minter"])

  name               = "${local.loadtest_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "controller" {
  name = "run-and-judge"
  role = aws_iam_role.task["controller"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunRunnersAndMinter"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [local.task_def_arn["k6"], local.task_def_arn["tokenMinter"]]
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.loadtest.arn }
        }
      },
      {
        Sid      = "WatchAndStopTasks"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:ListTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.loadtest.arn }
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
          aws_iam_role.task["k6"].arn,
          aws_iam_role.task["minter"].arn,
          aws_iam_role.execution["execution"].arn,
          aws_iam_role.execution["minter-execution"].arn,
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
        Resource = [for q in local.watched_queues : data.terraform_remote_state.sqs.outputs.queues[q].arn]
      },
      {
        Sid      = "ListResultsAndTokens"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.loadtest.arn]
        Condition = {
          StringLike = { "s3:prefix" = ["results/*", "tokens/*"] }
        }
      },
      {
        # 태스크별 k6 요약을 모아 plan · summary 를 쓴다
        Sid      = "ReadWriteResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/results/*"]
      },
      {
        Sid      = "DeleteTokens"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/tokens/*"]
      },
    ]
  })
}

# 시험 ID · 태스크 번호는 실행할 때 정해져 IAM 으로 한 태스크의 키까지 좁힐 수 없다. 대신 파일 이름 꼴로 좁히고 읽기 · 지우기를 주지 않아,
# 컨트롤러가 쓰는 summary 나 토큰은 고칠 수 없게 한다. 다른 태스크의 요약을 덮어쓸 수 있는 것은 받아들인다(모든 태스크가 같은 이미지다)
resource "aws_iam_role_policy" "k6" {
  name = "tokens-and-summary"
  role = aws_iam_role.task["k6"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTokens"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/tokens/*"]
      },
      {
        Sid      = "WriteOwnSummary"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/results/*/k6-*.json"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "minter" {
  name = "write-tokens"
  role = aws_iam_role.task["minter"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteTokens"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.loadtest.arn}/tokens/*"]
      },
    ]
  })
}

# ── 실행 역할 ─────────────────────────────────────────────
# 서명키는 공용 실행 역할(모든 앱 서비스)과 -minter-execution 만 읽는다. 새로 느는 주체는 발급기 하나다
locals {
  execution_secret = {
    execution        = local.header_secret_arn   # 컨트롤러 · k6 (컨트롤러 작업 정의에는 비밀이 없다)
    minter-execution = local.jwt_private_key_arn # 발급기
  }
}

resource "aws_iam_role" "execution" {
  for_each = local.execution_secret

  name               = "${local.loadtest_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  for_each = aws_iam_role.execution

  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  for_each = aws_iam_role.execution

  name = "read-secret"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.execution_secret[each.key]]
      },
    ]
  })
}
