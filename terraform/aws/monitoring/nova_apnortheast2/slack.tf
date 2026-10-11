# 경보 → Slack (AWS Chatbot). 두 리전의 SNS 토픽을 한 채널로 보낸다.
#
# 워크스페이스 연결(OAuth)은 Terraform 으로 할 수 없다. 콘솔에서 한 번 연결한 뒤
# terraform.tfvars 에 워크스페이스 · 채널 ID 를 넣는다. 비어 있으면 Slack 연결을 만들지 않는다.
#
# Chatbot API 는 서울 리전에 없어 us-west-2 로 호출한다 (설정 자체는 글로벌).
provider "aws" {
  alias  = "chatbot"
  region = "us-west-2"

  dynamic "assume_role" {
    for_each = var.assume_role_arn == "" ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = var.terraform_actor
    }
  }

  default_tags {
    tags = {
      Product   = var.product
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

locals {
  slack_enabled = var.slack_team_id != "" && var.slack_channel_id != ""
}

# Chatbot 이 Slack 에 경보 그래프를 그릴 때 쓰는 역할. 채널에서 할 수 있는 일도 이 범위로 묶는다(guardrail)
data "aws_iam_policy_document" "chatbot_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count = local.slack_enabled ? 1 : 0

  name               = "${local.name_prefix}-chatbot"
  description        = "AWS Chatbot: post CloudWatch alarms to Slack"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume.json
}

resource "aws_iam_role_policy_attachment" "chatbot" {
  count = local.slack_enabled ? 1 : 0

  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  provider = aws.chatbot
  count    = local.slack_enabled ? 1 : 0

  configuration_name    = "${local.name_prefix}-alerts"
  iam_role_arn          = aws_iam_role.chatbot[0].arn
  slack_team_id         = var.slack_team_id
  slack_channel_id      = var.slack_channel_id
  sns_topic_arns        = [aws_sns_topic.alerts.arn, aws_sns_topic.alerts_us_east_1.arn]
  guardrail_policy_arns = ["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
  logging_level         = "ERROR"
}

check "alerts_destination" {
  assert {
    condition     = local.slack_enabled
    error_message = "slack_team_id · slack_channel_id 가 비어 있어 경보가 아무 곳에도 가지 않는다. terraform.tfvars 에 넣는다."
  }
}
