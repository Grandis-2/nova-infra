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
