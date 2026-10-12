# 관측 스택(obs) 역할 — monitoring 스택의 ECS 태스크(Collector · Loki · Tempo · Mimir · Grafana · mysqld_exporter, NV-425)
#
# 태스크 역할 nova-prod-obs (컨테이너가 같이 쓴다)
#   Loki · Tempo · Mimir 버킷  읽기 · 쓰기 · 삭제 (compactor 의 보존 기간 삭제)
#   ECS Exec                  Grafana 포트 포워딩 (ssmmessages)
# 실행 역할 nova-prod-obs-execution
#   이미지 pull · 로그, Grafana admin 비밀번호를 컨테이너에 넣는다
#
# 역할 이름은 바꾸지 않는다. s3 스택의 관측 버킷 정책이 이 이름의 역할만 객체에 접근하게 막아 두었다.
# 처음에는 EC2 인스턴스 역할로 만들었다(nova-infra #22). 같은 역할의 신뢰 주체만 ECS 태스크로 바꾼다.
# 설정 내려받기 · SNS 발행 권한은 그 리소스를 만드는 티켓(NV-434 · NV-437)에서 더한다.
# 서비스 태스크 역할 · 공용 실행 역할에는 이 권한을 주지 않는다.
locals {
  obs_name        = "${local.name_prefix}-obs"
  obs_bucket_arns = [for b in ["loki_bucket", "tempo_bucket", "mimir_bucket"] : data.terraform_remote_state.s3.outputs[b].arn]
}

resource "aws_iam_role" "obs" {
  name               = local.obs_name
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "obs" {
  statement {
    sid       = "ObsBucketList"
    actions   = ["s3:ListBucket"]
    resources = local.obs_bucket_arns
  }

  statement {
    sid       = "ObsObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for arn in local.obs_bucket_arns : "${arn}/*"]
  }

  # ECS Exec 의 세션 채널. 대상을 좁힐 수 있는 리소스가 없다
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "obs" {
  name   = "obs-task"
  role   = aws_iam_role.obs.id
  policy = data.aws_iam_policy_document.obs.json
}

# 실행 역할 — 공용 실행 역할(execution.tf)은 ops/* 를 읽지 못하게 막아 두었으므로 따로 둔다
resource "aws_iam_role" "obs_execution" {
  name               = "${local.obs_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "obs_execution_managed" {
  role       = aws_iam_role.obs_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "obs_execution_secret" {
  name = "read-grafana-secret"
  role = aws_iam_role.obs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GrafanaAdminPassword"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [data.terraform_remote_state.secretsmanager.outputs.grafana_admin_secret_arn]
      },
    ]
  })
}
