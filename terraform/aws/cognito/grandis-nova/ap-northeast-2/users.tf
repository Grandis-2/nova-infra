# users.yml 의 사용자. 이메일이 곧 아이디다
locals {
  users = yamldecode(file("${path.module}/users.yml")).users

  role_groups = {
    admin  = "grafana-admin"
    editor = "grafana-editor"
  }
}

resource "aws_cognito_user" "this" {
  for_each = local.users

  user_pool_id             = aws_cognito_user_pool.grafana.id
  username                 = each.key
  desired_delivery_mediums = ["EMAIL"]

  attributes = {
    email          = each.key
    email_verified = "true"
  }

  lifecycle {
    precondition {
      condition     = contains(["admin", "editor", "viewer"], each.value)
      error_message = "users.yml 의 ${each.key} 역할이 ${each.value} 입니다. admin · editor · viewer 중 하나여야 합니다."
    }
  }
}

resource "aws_cognito_user_in_group" "this" {
  for_each = { for email, role in local.users : email => local.role_groups[role] if contains(keys(local.role_groups), role) }

  user_pool_id = aws_cognito_user_pool.grafana.id
  group_name   = aws_cognito_user_group.this[each.value].name
  username     = aws_cognito_user.this[each.key].username
}
