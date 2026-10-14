# monitoring/lgtm 스택(ALB 리스너 규칙 · Grafana OAuth 설정)이 읽는다

output "user_pool_arn" {
  value = aws_cognito_user_pool.grafana.arn
}

output "issuer_url" {
  description = "OIDC issuer. Grafana 의 토큰 검증 · JWKS 주소의 기준"
  value       = "https://${aws_cognito_user_pool.grafana.endpoint}"
}

output "domain" {
  description = "로그인 화면 도메인 (ALB authenticate-cognito 의 user_pool_domain 은 prefix 만 받는다)"
  value       = aws_cognito_user_pool_domain.grafana.domain
}

output "auth_base_url" {
  description = "Grafana generic OAuth 의 auth · token · userinfo 주소 기준"
  value       = "https://${aws_cognito_user_pool_domain.grafana.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "alb_client_id" {
  value = aws_cognito_user_pool_client.alb.id
}

output "grafana_client_id" {
  value = aws_cognito_user_pool_client.grafana.id
}

output "grafana_client_secret_arn" {
  value = aws_secretsmanager_secret.grafana_oauth.arn
}
