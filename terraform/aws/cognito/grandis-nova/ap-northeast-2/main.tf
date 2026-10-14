# ─────────────────────────────────────────────────────────────
# cognito — Grafana 로그인 (NV-517)
#
# 사용자는 AWS 계정이 아니라 이 풀의 사용자다(이메일 + 비밀번호). 가입은 막고 users.yml 로만 만든다.
#
#   브라우저 → CloudFront(edge) → ALB 리스너 규칙(authenticate-cognito, alb 클라이언트)
#           → Grafana(generic OAuth, grafana 클라이언트) — monitoring/lgtm 스택
#
# 두 클라이언트가 같은 풀을 쓰므로 ALB 에서 로그인하면 Grafana 는 비밀번호를 다시 묻지 않는다.
# Grafana 역할은 그룹으로 정한다: grafana-admin → Admin, grafana-editor → Editor, 그룹 없음 → Viewer
# ─────────────────────────────────────────────────────────────

locals {
  grafana_url = "https://${var.grafana_domain_name}"
}

resource "aws_cognito_user_pool" "grafana" {
  name = "${local.name_prefix}-grafana"

  # 지우면 사용자와 그룹이 모두 사라진다
  deletion_protection = "ACTIVE"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # 관리자(users.yml)만 만든다. 만들면 임시 비밀번호를 메일로 보내고, 첫 로그인 때 새 비밀번호로 바꾸게 한다
  admin_create_user_config {
    allow_admin_create_user_only = true

    invite_message_template {
      email_subject = "[nova] Grafana account"
      email_message = "Grafana(${local.grafana_url}) 계정이 만들어졌습니다.<br>아이디: {username}<br>임시 비밀번호: {####}<br>첫 로그인 때 새 비밀번호로 바꿉니다. 임시 비밀번호는 7일 동안 유효합니다."
      sms_message   = "Grafana id {username} temporary password {####}"
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # 추가 인증은 인증 앱(TOTP)만, 켜는 것은 사용자가 고른다. SMS 는 비용이 들어 쓰지 않는다
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = "${local.name_prefix}-grafana" }
}

# 로그인 화면 주소: https://<prefix>.auth.<region>.amazoncognito.com. 인증서가 필요 없다
resource "aws_cognito_user_pool_domain" "grafana" {
  domain       = "${local.name_prefix}-grafana"
  user_pool_id = aws_cognito_user_pool.grafana.id
}

# ALB 의 authenticate-cognito 가 쓴다. ALB 는 secret 을 Cognito 에서 직접 읽는다
resource "aws_cognito_user_pool_client" "alb" {
  name         = "${local.name_prefix}-grafana-alb"
  user_pool_id = aws_cognito_user_pool.grafana.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${local.grafana_url}/oauth2/idpresponse"]

  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
}

# Grafana 의 generic OAuth 가 쓴다. secret 은 Secrets Manager 로 넘긴다(secrets.tf)
resource "aws_cognito_user_pool_client" "grafana" {
  name         = "${local.name_prefix}-grafana-app"
  user_pool_id = aws_cognito_user_pool.grafana.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${local.grafana_url}/login/generic_oauth"]

  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
}

# ID 토큰의 cognito:groups 로 들어간다. Grafana 가 이 이름으로 역할을 정한다
resource "aws_cognito_user_group" "this" {
  for_each = {
    grafana-admin  = { precedence = 1, description = "Grafana Admin" }
    grafana-editor = { precedence = 2, description = "Grafana Editor (Explore)" }
  }

  name         = each.key
  user_pool_id = aws_cognito_user_pool.grafana.id
  precedence   = each.value.precedence
  description  = each.value.description
}
