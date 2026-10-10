# 표준 큐와 DLQ 한 쌍. DLQ 가 없으면 poison message 하나가 큐 전체를 막는다.

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  description = "큐 이름 (DLQ 는 -dlq 접미사)"
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "가시성 타임아웃(초). 최대 처리 시간의 2배 정도로 잡는다"
  type        = number
  default     = 360
}

variable "message_retention_seconds" {
  description = "보관 기간(초). 기본 4일"
  type        = number
  default     = 345600
}

variable "receive_wait_time_seconds" {
  description = "long polling 대기 시간(초). 빈 응답과 API 호출을 줄인다"
  type        = number
  default     = 20
}

variable "max_receive_count" {
  description = "이 횟수만큼 처리에 실패하면 DLQ 로 보낸다"
  type        = number
  default     = 5
}

variable "dlq_retention_seconds" {
  description = "DLQ 보관 기간(초). 원인을 찾을 시간을 두려고 최대치인 14일"
  type        = number
  default     = 1209600
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, { Name = "${var.name}-dlq", Role = "dlq" })
}

resource "aws_sqs_queue" "this" {
  name                       = var.name
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, { Name = var.name })
}

# DLQ 메시지를 원본 큐로 redrive 할 수 있게 한다
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this.arn]
  })
}

output "queue_arn" {
  value = aws_sqs_queue.this.arn
}

output "queue_url" {
  value = aws_sqs_queue.this.url
}

output "queue_name" {
  value = aws_sqs_queue.this.name
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dlq_name" {
  value = aws_sqs_queue.dlq.name
}
