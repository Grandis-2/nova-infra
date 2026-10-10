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
