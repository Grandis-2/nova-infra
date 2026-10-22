# 서비스 하나의 태스크 역할 — 앱 코드가 AWS API 를 부를 때 쓴다. 필요한 권한만 준다

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-${var.name}-task"
  assume_role_policy = var.assume_role_policy

  tags = { Service = var.name }
}

# ECS Exec(셸 접속)과 로그 기록은 모든 서비스에 필요하다
resource "aws_iam_role_policy" "base" {
  name = "base"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcsExec"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = var.log_group_arn
      },
    ]
  })
}

# 앱이 큐 이름으로 URL 을 찾으므로 GetQueueUrl 은 셋 다 필요하다
locals {
  queue_read_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
    "sqs:GetQueueUrl",
    "sqs:GetQueueAttributes",
  ]
}

resource "aws_iam_role_policy" "queue" {
  count = length(concat(var.send_queue_arns, var.consume_queue_arns, var.dlq_arns, var.dlq_send_arns)) > 0 ? 1 : 0

  name = "queue"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      length(var.send_queue_arns) > 0 ? [{
        Sid      = "Send"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = var.send_queue_arns
      }] : [],
      length(var.consume_queue_arns) > 0 ? [{
        Sid      = "Consume"
        Effect   = "Allow"
        Action   = local.queue_read_actions
        Resource = var.consume_queue_arns
      }] : [],
      length(var.dlq_arns) > 0 ? [{
        Sid      = "InspectDlq"
        Effect   = "Allow"
        Action   = local.queue_read_actions
        Resource = var.dlq_arns
      }] : [],
      length(var.dlq_send_arns) > 0 ? [{
        Sid      = "SendToDlq"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = var.dlq_send_arns
      }] : [],
    )
  })
}

# 업로드 버킷의 사진. catalog 가 올리고(uploads), 정리 배치가 안 쓰는 사진을 지운다(upload_cleanup). 조회는 CloudFront(cdn 스택)
# 키는 catalog ImagePurpose 의 접두 아래에만 생긴다. 용도를 늘리면 여기도 더한다 — 빠지면 그 용도의 업로드가 AccessDenied(503)다
locals {
  upload_objects = [for p in ["products/", "promotions/", "banners/"] : "${var.upload_bucket_arn}/${p}*"]
}

resource "aws_iam_role_policy" "upload" {
  count = var.uploads || var.upload_cleanup ? 1 : 0

  name = "upload"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.uploads ? [{
        Sid      = "PutImages"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = local.upload_objects
      }] : [],
      var.upload_cleanup ? [{
        Sid      = "DeleteImages"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = local.upload_objects
      }] : [],
    )
  })
}

# 다른 서비스의 최소 대수 바꾸기 (service.yml 의 scales). preorder 가 회차 일정에 맞춰 waitingroom · preorder 를 미리 늘린다.
# Application Auto Scaling 은 ECS 대상을 등록할 때 부르는 쪽에게 그 ECS 서비스의 DescribeServices · UpdateService 를 요구한다.
# 그래서 확장 대상 ARN(무작위 id) 대신 ECS 권한을 대상 서비스로 좁혀 바꿀 수 있는 서비스를 묶는다
resource "aws_iam_role_policy" "scaling" {
  count = length(var.scale_service_arns) > 0 ? 1 : 0

  name = "scaling"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ScalableTargets"
        Effect   = "Allow"
        Action   = ["application-autoscaling:DescribeScalableTargets", "application-autoscaling:RegisterScalableTarget"]
        Resource = "*"
      },
      {
        Sid      = "ScaledServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = var.scale_service_arns
      },
    ]
  })
}
