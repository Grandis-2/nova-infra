# Grafana 사용자. users.sops.yml(common KMS 키로 암호화해 커밋)을 풀어 만든다. 이메일이 곧 아이디다.
#
#   admin:              # grafana-admin 그룹 (Grafana Admin)
#     - alice@example.com
#   editor:             # grafana-editor 그룹 (Grafana Editor, Explore 사용)
#     - bob@example.com
#   viewer:             # 그룹 없음 (Grafana Viewer)
#     - judge@example.com
#
# sops 는 값만 암호화하고 키는 평문으로 둔다. 그래서 이메일은 반드시 값(목록 항목)에 둔다 — 키에 두면 그대로 드러난다.
# 저장소와 Atlantis plan 댓글이 공개라 plan 에도 이메일이 드러나지 않게 한다.
#   - 리소스 키는 이메일 해시 앞 16자리, 아이디 · 이메일 속성은 sensitive → plan 에는 해시와 (sensitive value) 만 보인다
#   - 평문 이메일은 상태 파일(비공개 S3)에만 남는다. Cognito 사용자 리소스가 아이디를 상태에 두므로 피할 수 없다
# 고칠 때는 `sops terraform/aws/cognito/grandis-nova/ap-northeast-2/users.sops.yml` → PR → apply.
# 추가하면 임시 비밀번호가 메일로 가고, 지우면 계정이 사라진다.
# 파일이 생기면 읽기 전용 역할은 KMS 복호화 권한이 없어 이 스택을 Atlantis 나 관리자만 plan 할 수 있다.

locals {
  users_file = "${path.module}/users.sops.yml"

  role_groups = {
    admin  = "grafana-admin"
    editor = "grafana-editor"
  }
}

# 사용자 리소스의 for_each 키를 만들어야 해서 ephemeral 이 아니라 data 로 푼다 (값은 sensitive 로 표시된다)
data "sops_file" "users" {
  count = fileexists(local.users_file) ? 1 : 0

  source_file = local.users_file
  input_type  = "yaml"
}

locals {
  user_roles_allowed = ["admin", "editor", "viewer"]

  users_doc = length(data.sops_file.users) == 0 ? {} : coalesce(yamldecode(data.sops_file.users[0].raw), {})

  # 이메일 → 역할 목록. 중복을 그대로 키로 쓰면 Terraform 오류 메시지에 이메일이 찍히므로(PR 댓글 공개) 묶어서 따로 센다
  users_grouped = { for u in flatten([
    for role in local.user_roles_allowed : [
      for email in coalesce(try(local.users_doc[role], null), []) : { email = lower(trimspace(email)), role = role }
    ]
  ]) : u.email => u.role... }

  users_duplicated = nonsensitive(length([for email, roles in local.users_grouped : email if length(roles) > 1]))

  # 해시 키 → 이메일(sensitive) · 역할
  users_by_key = { for email, roles in local.users_grouped : substr(sha256(email), 0, 16) => { email = sensitive(email), role = roles[0] } }

  # 해시 키 → 역할. 키와 역할은 비밀이 아니므로 표시를 풀어 for_each 에 쓴다
  user_roles = nonsensitive({ for k, u in local.users_by_key : k => u.role })

  # admin · editor · viewer 밖의 키는 읽지 않는다. 오타로 사용자가 빠지지 않게 plan 에서 막는다
  users_unknown_keys = nonsensitive(setsubtract(keys(local.users_doc), local.user_roles_allowed))
}

resource "aws_cognito_user" "this" {
  for_each = local.user_roles

  user_pool_id             = aws_cognito_user_pool.grafana.id
  username                 = sensitive(local.users_by_key[each.key].email)
  desired_delivery_mediums = ["EMAIL"]

  attributes = {
    email          = sensitive(local.users_by_key[each.key].email)
    email_verified = "true"
  }
}

resource "aws_cognito_user_in_group" "this" {
  for_each = { for k, role in local.user_roles : k => local.role_groups[role] if contains(keys(local.role_groups), role) }

  user_pool_id = aws_cognito_user_pool.grafana.id
  group_name   = aws_cognito_user_group.this[each.value].name
  username     = aws_cognito_user.this[each.key].username
}

# users.sops.yml 의 최상위 키 검사. 사용자가 없어도 돌도록 사용자 리소스가 아닌 따로 둔 리소스에 건다
resource "terraform_data" "users_file_check" {
  input = 0

  lifecycle {
    precondition {
      condition     = length(local.users_unknown_keys) == 0
      error_message = "users.sops.yml 에 모르는 키가 있습니다: ${join(", ", local.users_unknown_keys)}. admin · editor · viewer 만 씁니다."
    }

    precondition {
      condition     = local.users_duplicated == 0
      error_message = "users.sops.yml 에서 두 역할 이상에 들어간 이메일이 ${local.users_duplicated}개 있습니다. 한 역할에만 둡니다."
    }
  }
}
