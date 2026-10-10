output "queues" {
  description = "큐 이름 -> { arn, url, name, dlq_arn, dlq_url, dlq_name }"
  value = {
    for k, m in module.queue : k => {
      arn      = m.queue_arn
      url      = m.queue_url
      name     = m.queue_name
      dlq_arn  = m.dlq_arn
      dlq_url  = m.dlq_url
      dlq_name = m.dlq_name
    }
  }
}

output "scheduler_dlq" {
  value = {
    arn  = aws_sqs_queue.scheduler_dlq.arn
    name = aws_sqs_queue.scheduler_dlq.name
  }
}
