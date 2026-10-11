output "upload_bucket" {
  value = {
    id                          = aws_s3_bucket.this["upload"].id
    arn                         = aws_s3_bucket.this["upload"].arn
    bucket_regional_domain_name = aws_s3_bucket.this["upload"].bucket_regional_domain_name
  }
}

output "log_bucket" {
  value = {
    id  = aws_s3_bucket.this["log"].id
    arn = aws_s3_bucket.this["log"].arn
  }
}

output "loki_bucket" {
  description = "관측 호스트의 Loki 저장소. iam 스택(obs 역할 권한)과 obs 스택(LOKI_S3_BUCKET)이 읽는다"
  value = {
    id  = aws_s3_bucket.this["loki"].id
    arn = aws_s3_bucket.this["loki"].arn
  }
}
