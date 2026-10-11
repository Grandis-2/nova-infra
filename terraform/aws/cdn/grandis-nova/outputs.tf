output "image_base_url" {
  description = "업로드 이미지 URL 접두사. 뒤에 객체 키를 붙인다"
  value       = local.use_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "distribution_id" {
  description = "같은 키로 다시 올렸을 때 캐시 무효화에 쓴다"
  value       = aws_cloudfront_distribution.this.id
}
