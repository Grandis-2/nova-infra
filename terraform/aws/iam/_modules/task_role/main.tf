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
  count = length(concat(var.send_queue_arns, var.consume_queue_arns, var.dlq_arns)) > 0 ? 1 : 0

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
    )
  })
}

# 앱이 presigned URL 에 서명하면 브라우저가 버킷에 직접 PUT 한다. 조회는 CloudFront(cdn 스택)
resource "aws_iam_role_policy" "upload" {
  count = var.uploads ? 1 : 0

  name = "upload"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "UploadImages"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${var.upload_bucket_arn}/*"
    }]
  })
}
