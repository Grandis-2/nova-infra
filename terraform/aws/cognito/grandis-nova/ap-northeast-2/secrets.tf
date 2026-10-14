# Grafana 클라이언트 secret. obs 실행 역할이 이름 규칙(ops/grafana/oauth-client-secret-??????)으로 읽는다 (iam 스택 obs.tf).
# 클라이언트를 다시 만들면 secret 이 바뀌므로 쓰기 전용(wo)이 아니라 값을 그대로 따라가게 둔다. 값은 cognito 상태에도 있다
resource "aws_secretsmanager_secret" "grafana_oauth" {
  name                    = "${local.name_prefix}/ops/grafana/oauth-client-secret"
  description             = "Cognito app client secret for Grafana generic OAuth"
  recovery_window_in_days = 7

  tags = { Service = "obs" }
}

resource "aws_secretsmanager_secret_version" "grafana_oauth" {
  secret_id     = aws_secretsmanager_secret.grafana_oauth.id
  secret_string = aws_cognito_user_pool_client.grafana.client_secret
}
