output "alb_certificate_arn" {
  description = "ecs 스택의 ALB 리스너가 쓴다"
  # 검증이 끝난 ARN 을 내보내 다른 스택이 발급 전 인증서를 쓰지 않게 한다 (영역이 없어 검증을 안 하면 인증서 ARN)
  value = local.enabled ? try(aws_acm_certificate_validation.alb[0].certificate_arn, aws_acm_certificate.alb[0].arn) : ""
}

output "cloudfront_certificate_arn" {
  description = "edge 스택이 읽는다"
  value       = local.enabled ? try(aws_acm_certificate_validation.cloudfront[0].certificate_arn, aws_acm_certificate.cloudfront[0].arn) : ""
}

output "domain_name" {
  value = var.domain_name
}

output "grafana_domain_name" {
  value = local.grafana_enabled ? var.grafana_domain_name : ""
}

output "grafana_alb_certificate_arn" {
  description = "monitoring/lgtm 스택이 ALB 리스너에 SNI 로 붙인다"
  value       = local.grafana_enabled ? try(aws_acm_certificate_validation.grafana_alb[0].certificate_arn, aws_acm_certificate.grafana_alb[0].arn) : ""
}

output "grafana_cloudfront_certificate_arn" {
  description = "edge 스택의 Grafana CloudFront 가 쓴다"
  value       = local.grafana_enabled ? try(aws_acm_certificate_validation.grafana_cloudfront[0].certificate_arn, aws_acm_certificate.grafana_cloudfront[0].arn) : ""
}

output "rum_domain_name" {
  value = local.rum_enabled ? var.rum_domain_name : ""
}

output "rum_alb_certificate_arn" {
  description = "monitoring/lgtm 스택이 브라우저 수집기용 ALB 리스너 규칙과 함께 SNI 로 붙인다"
  value       = local.rum_enabled ? try(aws_acm_certificate_validation.rum_alb[0].certificate_arn, aws_acm_certificate.rum_alb[0].arn) : ""
}

output "rum_cloudfront_certificate_arn" {
  description = "edge 스택의 수집용 CloudFront 가 쓴다"
  value       = local.rum_enabled ? try(aws_acm_certificate_validation.rum_cloudfront[0].certificate_arn, aws_acm_certificate.rum_cloudfront[0].arn) : ""
}

output "atlantis_domain_name" {
  value = local.atlantis_enabled ? var.atlantis_domain_name : ""
}

output "atlantis_alb_certificate_arn" {
  description = "ecs 스택이 메인 ALB 리스너에 SNI 로 붙인다"
  value       = local.atlantis_enabled ? try(aws_acm_certificate_validation.atlantis_alb[0].certificate_arn, aws_acm_certificate.atlantis_alb[0].arn) : ""
}

output "atlantis_cloudfront_certificate_arn" {
  description = "edge 스택의 Atlantis CloudFront 가 쓴다"
  value       = local.atlantis_enabled ? try(aws_acm_certificate_validation.atlantis_cloudfront[0].certificate_arn, aws_acm_certificate.atlantis_cloudfront[0].arn) : ""
}
