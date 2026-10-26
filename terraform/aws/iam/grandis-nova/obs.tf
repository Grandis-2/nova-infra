# 관측 스택(obs) 역할 — monitoring 스택의 ECS 태스크(Collector · Loki · Tempo · Mimir · Grafana · mysqld_exporter, NV-425)
#
# 태스크 역할 nova-prod-obs (컨테이너가 같이 쓴다)
#   Loki · Tempo · Mimir 버킷  읽기 · 쓰기 · 삭제 (compactor 의 보존 기간 삭제)
#   ECS Exec                  Grafana 포트 포워딩 (ssmmessages)
#   obs-config 버킷          init 컨테이너가 설정 파일(monitoring 스택의 lgtm/)을 받는다
#   SNS 경보 토픽            Grafana 경보를 monitoring 스택의 토픽(→ Chatbot → Slack)으로 보낸다
#   SNS 관리자 알림 토픽     관리자 알림 경보를 sqs 스택의 토픽(→ admin-alert-grafana 큐 → member)으로 보낸다
#   CloudWatch 읽기          Grafana CloudWatch 데이터소스(SQS · ElastiCache · ECS · ALB · CloudFront 지표 조회)
# 실행 역할 nova-prod-obs-execution
#   이미지 pull · 로그, Grafana admin 비밀번호와 mysqld_exporter DB 비밀번호를 컨테이너에 넣는다
# 인스턴스 역할 nova-prod-obs-instance
#   obs 태스크를 올리는 ECS 컨테이너 인스턴스. ECS 에이전트 · SSM, 부팅 때 데이터 EBS 를 붙인다
#
# 역할 이름은 바꾸지 않는다. s3 스택의 관측 버킷 정책이 이 이름의 역할만 객체에 접근하게 막아 두었다.
# 처음에는 EC2 인스턴스 역할로 만들었다(nova-infra #22). 같은 역할의 신뢰 주체만 ECS 태스크로 바꾼다.
# 서비스 태스크 역할 · 공용 실행 역할에는 이 권한을 주지 않는다.
locals {
  obs_name        = "${local.name_prefix}-obs"
  obs_bucket_arns = [for b in ["loki_bucket", "tempo_bucket", "mimir_bucket"] : data.terraform_remote_state.s3.outputs[b].arn]
  obs_config_arn  = data.terraform_remote_state.s3.outputs.obs_config_bucket.arn

  # monitoring 스택(층 6)의 경보 토픽. 이름 규칙으로 ARN 을 만든다 (monitoring 이 iam 뒤라 remote state 로 읽을 수 없다)
  alerts_topic_arn = "arn:${local.partition}:sns:${var.aws_region}:${local.account_id}:${local.name_prefix}-alerts"

  # ecs 스택(층 5)이 만드는 obs 데이터 EBS 의 Name 태그. 인스턴스 역할은 이 태그가 붙은 볼륨만 붙일 수 있다
  obs_data_volume_name = "${local.name_prefix}-obs-data"
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

  statement {
    sid       = "ObsConfigRead"
    actions   = ["s3:ListBucket", "s3:GetObject"]
    resources = [local.obs_config_arn, "${local.obs_config_arn}/*"]
  }

  statement {
    sid       = "AlertsPublish"
    actions   = ["sns:Publish"]
    resources = [local.alerts_topic_arn, data.terraform_remote_state.sqs.outputs.admin_alert_topic.arn]
  }

  # Grafana CloudWatch 데이터소스(지표만. Logs Insights 는 쓰지 않는다 — 조회한 데이터 양만큼 과금된다).
  # 지표 조회 API 는 리소스로 좁힐 수 없다(전부 읽기). 변수 목록에 쓰는 것:
  #   DescribeRegions(리전) · tag:GetResources(태그로 CloudFront 배포 거르기) · DescribeInstances(이름 태그로 NAT · obs 인스턴스 고르기 — ASG 가 바꿔 ID 가 변한다)
  # GetServiceQuota 는 지표 식의 SERVICE_QUOTA()(Fargate vCPU 한도 사용률)가 쓴다
  statement {
    sid = "CloudWatchMetricsRead"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:DescribeAlarmsForMetric",
      "ec2:DescribeRegions",
      "ec2:DescribeInstances",
      "tag:GetResources",
      "servicequotas:GetServiceQuota",
    ]
    resources = ["*"]
  }

  # 패널의 경보 표시 · 경보 이력. 이 계정의 경보만(서울 · CloudFront 경보가 있는 us-east-1)
  statement {
    sid       = "CloudWatchAlarmsRead"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]
    resources = ["arn:${local.partition}:cloudwatch:*:${local.account_id}:alarm:*"]
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

# 정책 이름은 처음 만든 그대로 둔다(바꾸면 지웠다 다시 만든다). Grafana(admin · OAuth) 와 mysqld_exporter 비밀을 읽는다
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
      # mysqld_exporter 계정 (rds 스택 secrets.tf). 이름 규칙으로 준다 — ARN 끝 6자리는 Secrets Manager 가 붙인다
      {
        Sid      = "MysqldExporterPassword"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/db/exporter-??????"]
      },
      # Grafana 의 Cognito OAuth 클라이언트 secret (cognito 스택). 같은 이유로 이름 규칙으로 준다
      {
        Sid      = "GrafanaOAuthClientSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/ops/grafana/oauth-client-secret-??????"]
      },
    ]
  })
}

# ── 컨테이너 인스턴스 역할 ──────────────────────────────────────
# obs 용량 공급자(ecs 스택)의 EC2. 태스크는 위 태스크 역할을 쓰고, 태스크에서는 인스턴스 메타데이터를 막는다
# (ecs.config 의 ECS_AWSVPC_BLOCK_IMDS). 그래서 이 역할의 권한은 컨테이너에 닿지 않는다.
resource "aws_iam_role" "obs_instance" {
  name               = "${local.obs_name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "obs_instance_managed" {
  for_each = toset([
    "service-role/AmazonEC2ContainerServiceforEC2Role",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.obs_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# 인스턴스가 바뀌어도 WAL · TSDB · Grafana DB 가 남도록 데이터 EBS 를 부팅 때 붙인다 (ecs 스택 obs.tf 의 user_data).
# 붙일 수 있는 것은 Name 태그가 obs 데이터 볼륨인 것, 붙는 쪽은 이 프로파일을 쓰는 인스턴스뿐이다.
data "aws_iam_policy_document" "obs_instance" {
  statement {
    sid       = "DescribeVolumes"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }

  statement {
    sid       = "AttachDataVolume"
    actions   = ["ec2:AttachVolume"]
    resources = ["arn:${local.partition}:ec2:${var.aws_region}:${local.account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = [local.obs_data_volume_name]
    }
  }

  statement {
    sid       = "AttachToObsInstance"
    actions   = ["ec2:AttachVolume"]
    resources = ["arn:${local.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "ArnEquals"
      variable = "ec2:InstanceProfile"
      values   = [aws_iam_instance_profile.obs_instance.arn]
    }
  }
}

resource "aws_iam_role_policy" "obs_instance" {
  name   = "attach-obs-data-volume"
  role   = aws_iam_role.obs_instance.id
  policy = data.aws_iam_policy_document.obs_instance.json
}

resource "aws_iam_instance_profile" "obs_instance" {
  name = "${local.obs_name}-instance"
  role = aws_iam_role.obs_instance.name
}
