# VPC Flow Logs → CloudWatch Logs. 로그 그룹, 전달 역할, Flow Log 를 함께 만든다.
# 역할 권한은 VPC 문서(flow-logs-iam-role)의 최소 권한을 Service Authorization Reference 의 리소스 유형에 맞춰 좁혔다.

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/vpc/${var.name_prefix}"
  retention_in_days = var.retention_in_days
}

# Flow Logs 서비스만 이 역할을 맡을 수 있다. 출처 계정 · Flow Log ARN 조건으로 confused deputy 를 막는다 (AWS 권장)
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-vpc-flow-log"
  description        = "Delivers VPC Flow Logs to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# 액션마다 권한을 확인하는 리소스 유형이 다르다 (Service Authorization Reference)
#   DescribeLogGroups               리소스 수준 권한 없음 → *
#   DescribeLogStreams              log-group
#   CreateLogStream · PutLogEvents  log-stream
# 로그 그룹은 이 모듈이 만들므로 CreateLogGroup 은 주지 않는다
data "aws_iam_policy_document" "write" {
  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
  statement {
    actions   = ["logs:DescribeLogStreams"]
    resources = [aws_cloudwatch_log_group.this.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "write" {
  name   = "write-logs"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.write.json
}

resource "aws_flow_log" "this" {
  vpc_id               = var.vpc_id
  traffic_type         = var.traffic_type
  iam_role_arn         = aws_iam_role.this.arn
  log_destination      = aws_cloudwatch_log_group.this.arn
  log_destination_type = "cloud-watch-logs"

  tags = { Name = "${var.name_prefix}-flow-log" }

  # 권한이 붙기 전에 Flow Log 가 만들어지면 첫 전달이 실패한다
  depends_on = [aws_iam_role_policy.write]
}
