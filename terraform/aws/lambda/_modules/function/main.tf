# Lambda 함수 하나 — 코드 묶기 · 실행 역할 · 로그 그룹 · 비동기 재시도 · 오류 경보를 함께 만든다.
# 코드는 저장소의 functions/<이름> 에 두고, 함수마다 다른 것(트리거 · API 권한 · 환경 변수)만 부르는 스택이 정한다.
#
# 표준 라이브러리 · 런타임에 든 boto3 만 쓴다고 가정한다. 외부 패키지가 필요해지면 묶기 단계를 따로 둔다.

locals {
  function_name = "${var.name_prefix}-${var.name}"
  in_vpc        = length(var.subnet_ids) > 0
}

data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.name}.zip"
  excludes    = ["tests", "tests/**", "__pycache__", "__pycache__/**", "**/__pycache__/**"]
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:함수 실행 로그다. 다른 로그 그룹과 같이 기본 암호화(AWS 관리)를 쓴다
  #checkov:skip=CKV_AWS_338:처리 결과 확인용이라 짧게 둔다. 원본은 각 함수가 읽는 곳(S3 등)에 남는다
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "this" {
  name = "${local.function_name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 로그는 자기 로그 그룹에만 쓴다(관리형 AWSLambdaBasicExecutionRole 은 모든 로그 그룹을 연다)
resource "aws_iam_role_policy" "logs" {
  name = "logs"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.this.arn}:*"
    }]
  })
}

# VPC 안에서 돌면 ENI 를 만들고 지울 권한이 필요하다
resource "aws_iam_role_policy_attachment" "vpc" {
  count = local.in_vpc ? 1 : 0

  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaENIManagementAccess"
}

resource "aws_iam_role_policy" "extra" {
  count = var.policy_json != "" ? 1 : 0

  name   = "function"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_116:비동기 실패는 재시도 뒤 오류 경보로 알린다. 다시 처리할 원본은 트리거 쪽(S3 등)에 남는다
  #checkov:skip=CKV_AWS_173:환경 변수에 비밀을 넣지 않는다(변수 설명). 기본 암호화로 충분하다
  #checkov:skip=CKV_AWS_272:코드는 이 저장소에서 Terraform 이 직접 묶어 올린다. 서명할 배포 경로가 따로 없다
  #checkov:skip=CKV_AWS_50:짧은 일괄 처리라 X-Ray 트레이스를 보지 않는다
  #checkov:skip=CKV_AWS_115:계정 동시 실행 한도가 10 이라 예약할 수 없다(reserved_concurrency 설명). 계정 한도가 상한이 된다
  #checkov:skip=CKV_AWS_117:VPC 가 필요 없는 함수도 이 모듈을 쓴다. VPC 안 대상을 부르는 함수는 subnet_ids 를 넘긴다
  function_name = local.function_name
  description   = var.description
  role          = aws_iam_role.this.arn

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  handler          = var.handler
  runtime          = var.runtime
  architectures    = ["arm64"]
  memory_size      = var.memory_size
  timeout          = var.timeout

  reserved_concurrent_executions = var.reserved_concurrency

  dynamic "environment" {
    for_each = length(var.environment) > 0 ? [1] : []
    content {
      variables = var.environment
    }
  }

  dynamic "vpc_config" {
    for_each = local.in_vpc ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  # 역할 권한이 붙기 전에 함수가 만들어지면 첫 호출이 로그 · ENI 권한 없이 실패한다
  depends_on = [
    aws_iam_role_policy.logs,
    aws_iam_role_policy_attachment.vpc,
  ]
}

resource "aws_lambda_function_event_invoke_config" "this" {
  function_name                = aws_lambda_function.this.function_name
  maximum_retry_attempts       = var.max_retry_attempts
  maximum_event_age_in_seconds = 3600
}

# 실패한 호출이 있으면 알린다(재시도로 결국 성공한 호출의 첫 실패도 센다). 처리할 일이 없으면 지표가 없으므로 결측은 정상이다
resource "aws_cloudwatch_metric_alarm" "errors" {
  count = var.alarm_topic_arn != "" ? 1 : 0

  alarm_name          = "${local.function_name}-errors"
  alarm_description   = "Lambda ${local.function_name} failed. Check its log group /aws/lambda/${local.function_name}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]
}
