# 서비스별 태스크 역할 — terraform/application/<서비스>/service.yml 에서 만든다
#   queues  → 보내기 · 받기 · DLQ 들여다보기 · DLQ 에 바로 넣기 권한
#   uploads · upload_cleanup → 이미지 업로드 버킷에 사진 올리기 · 지우기
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
  dlq_send_arns      = [for q in each.value.queues.dlq_send : local.queues[q].dlq_arn]

  uploads           = each.value.uploads
  upload_cleanup    = each.value.upload_cleanup
  upload_bucket_arn = local.upload_bucket
}

# 업로드 버킷 권한(올리기 · 지우기)을 주기 전에, upload 버킷 정책에 비TLS 요청 거부가 실제로 걸려 있는지 확인한다.
# 정책은 cdn 스택이 붙인다. 적용 순서에 기대지 않고 실제 버킷 정책을 읽어 확인한다 (정책이 없으면 조회 자체가 실패한다).
# 문자열이 아니라 구문을 본다: 모든 주체 · s3:* · 버킷과 객체 · SecureTransport=false 를 거부하는 Deny 가 있어야 한다.
data "aws_s3_bucket_policy" "upload" {
  count  = anytrue([for v in local.services : v.uploads || v.upload_cleanup]) ? 1 : 0
  bucket = data.terraform_remote_state.s3.outputs.upload_bucket.id

  lifecycle {
    postcondition {
      condition = anytrue([
        for st in try(flatten([jsondecode(self.policy).Statement]), []) : try(
          st.Effect == "Deny"
          && jsonencode(st.Principal) == jsonencode("*")
          && contains(flatten([st.Action]), "s3:*")
          && length(setsubtract([local.upload_bucket, "${local.upload_bucket}/*"], flatten([st.Resource]))) == 0
          # 조건이 더 붙으면 거부 범위가 좁아지므로 SecureTransport=false 하나만 있어야 한다 (값은 문자열 · 배열 모두 허용)
          && contains([
            jsonencode({ Bool = { "aws:SecureTransport" = "false" } }),
            jsonencode({ Bool = { "aws:SecureTransport" = ["false"] } }),
          ], jsonencode(st.Condition)),
          false
        )
      ])
      error_message = "upload 버킷 정책에 비TLS 요청 거부(aws:SecureTransport)가 없습니다. cdn 스택을 먼저 적용한 뒤 uploads · upload_cleanup 을 켜세요."
    }
  }
}
