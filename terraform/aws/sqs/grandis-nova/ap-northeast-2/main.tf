# 비동기 처리 큐. 백엔드 설정에 큐 이름이 고정돼 있어 접두사를 붙이지 않는다.
# 계정·리전마다 환경이 하나뿐이라 이름이 겹치지 않는다.
# 송수신 권한은 application/<서비스>/service.yml 의 queues 로 정한다.

module "queue" {
  source = "../../_modules/queue"

  for_each = toset(var.queues)

  name                       = each.key
  visibility_timeout_seconds = var.visibility_timeout
  max_receive_count          = var.max_receive_count
}

# EventBridge Scheduler 의 RunTask 호출이 실패하면 여기로 온다
resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${local.name_prefix}-scheduler-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${local.name_prefix}-scheduler-dlq"
    Role = "dlq"
  }
}
