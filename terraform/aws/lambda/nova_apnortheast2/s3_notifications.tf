# S3 이벤트 → Lambda. 버킷 알림 설정은 버킷마다 리소스 하나가 전부를 정한다.
# 같은 버킷에 함수를 더하면 이 리소스에 lambda_function 블록을 더한다(리소스를 따로 만들면 서로 덮어쓴다).

# ── 로그 버킷 (s3 스택 소유) ─────────────────────────────────
resource "aws_lambda_permission" "edge_logs_s3" {
  statement_id   = "AllowLogBucket"
  action         = "lambda:InvokeFunction"
  function_name  = module.edge_logs.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = local.log_bucket.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket_notification" "log" {
  bucket = local.log_bucket.id

  dynamic "lambda_function" {
    for_each = local.edge_log_prefixes
    content {
      lambda_function_arn = module.edge_logs.function_arn
      events              = ["s3:ObjectCreated:*"]
      filter_prefix       = lambda_function.value
    }
  }

  depends_on = [aws_lambda_permission.edge_logs_s3]
}

data "aws_caller_identity" "current" {}
