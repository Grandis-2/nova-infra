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

output "rum_collect_url" {
  description = "브라우저 실사용자 모니터링(Faro) 수집 주소. 프런트 VITE_FARO_URL"
  value       = local.rum_enabled ? "https://${local.rum_domain}${local.rum_collect_path}" : ""
}
