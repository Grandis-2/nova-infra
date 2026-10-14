output "cloudfront_domain_name" {
  description = "도메인이 없을 때 접속할 주소"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  description = "배포 후 캐시 무효화에 쓴다"
  value       = aws_cloudfront_distribution.this.id
}

output "service_url" {
  value = local.use_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "grafana_url" {
  description = "Grafana 공개 주소 (Cognito 로그인, NV-517)"
  value       = local.grafana_enabled ? "https://${local.grafana_domain}" : ""
}
