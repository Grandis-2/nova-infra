output "tfstate_bucket" {
  description = "원격 상태 버킷 이름"
  value       = aws_s3_bucket.tfstate.id
}
