# 관리자 알림 주제 (NV-825). Grafana 경보 규칙이 판정한 서버 상태 알림을 member(관리자 알림 허브)로 넘긴다.
# Grafana(obs 태스크 역할, iam 스택 obs.tf) → 이 주제 → admin-alert-grafana 큐 → member.
# 메시지 본문은 Grafana 템플릿(lgtm 스택 notify.yaml 의 admin.message)이 만든 JSON 그대로다(원문 전달).
# Slack 경보 주제(nova-prod-alerts)는 monitoring 스택에 있다. 이것은 경보가 아니라 앱으로 가는 길이라 받는 큐와 같이 둔다.

locals {
  admin_alert_queue = module.queue["admin-alert-grafana"]
}

# 주제 정책은 기본값(이 계정의 IAM 권한을 따른다)으로 두고, 게시 권한은 obs 태스크 역할(iam 스택 obs.tf) 한 곳에서만 준다.
# 역할 ARN 을 이름 규칙으로 만들어 주제 정책에서 더 좁힐 수도 있지만, 게시하는 쪽이 obs 역할 하나라 IAM 쪽에서만 관리한다
resource "aws_sns_topic" "admin_alert" {
  name = "${local.name_prefix}-admin-alert"

  tags = { Name = "${local.name_prefix}-admin-alert" }
}

resource "aws_sns_topic_subscription" "admin_alert" {
  topic_arn            = aws_sns_topic.admin_alert.arn
  protocol             = "sqs"
  endpoint             = local.admin_alert_queue.queue_arn
  raw_message_delivery = true
}

data "aws_iam_policy_document" "admin_alert_queue" {
  statement {
    sid       = "AllowAdminAlertTopic"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [local.admin_alert_queue.queue_arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.admin_alert.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "admin_alert" {
  queue_url = local.admin_alert_queue.queue_url
  policy    = data.aws_iam_policy_document.admin_alert_queue.json
}
