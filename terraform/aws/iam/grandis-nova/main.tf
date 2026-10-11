# 서비스별 태스크 역할 — terraform/application/<서비스>/service.yml 에서 만든다
#   queues  → 보내기 · 받기 · DLQ 권한
#   uploads → 이미지 업로드 버킷 쓰기
# KMS 권한은 주지 않는다. JWT 서명은 시크릿의 PEM 개인키로 한다.

module "task_role" {
  source   = "../_modules/task_role"
  for_each = local.services

  name_prefix        = local.name_prefix
  name               = each.value.name
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  log_group_arn      = local.log_group_arn

  send_queue_arns    = [for q in each.value.queues.send : local.queues[q].arn]
  consume_queue_arns = [for q in each.value.queues.consume : local.queues[q].arn]
  dlq_arns           = [for q in each.value.queues.dlq : local.queues[q].dlq_arn]

  uploads           = each.value.uploads
  upload_bucket_arn = local.upload_bucket
}

# 업로드 쓰기 권한(presigned PUT)을 주기 전에, upload 버킷 정책에 비TLS 요청 거부가 실제로 걸려 있는지 확인한다.
# 정책은 cdn 스택이 붙인다. 적용 순서에 기대지 않고 실제 버킷 정책을 읽어 확인한다 (정책이 없으면 조회 자체가 실패한다).
data "aws_s3_bucket_policy" "upload" {
  count  = anytrue([for v in local.services : v.uploads]) ? 1 : 0
  bucket = data.terraform_remote_state.s3.outputs.upload_bucket.id

  lifecycle {
    postcondition {
      condition     = strcontains(self.policy, "aws:SecureTransport")
      error_message = "upload 버킷 정책에 비TLS 요청 거부(aws:SecureTransport)가 없습니다. cdn 스택을 먼저 적용한 뒤 uploads: true 를 켜세요."
    }
  }
}
