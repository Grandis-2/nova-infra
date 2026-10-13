# 서비스 비밀 — 외부에서 받는 값(카카오, 토스 등). Terraform 이 만들 수 있는 비밀은 generated.tf.
# application/<서비스>/secrets.sops.yml(common KMS 키로 암호화해 커밋)을 풀어
# 서비스마다 Secrets Manager 시크릿 하나(nova-prod/app/<서비스>)에 넣는다.
# 파일의 키 이름이 곧 컨테이너 환경변수 이름이다 (ecs 스택이 키마다 연결한다).
#
# 값은 콘솔에서 고치지 않는다. `sops <파일>` 로 고치고 PR → apply 한다.
# 이미 떠 있는 태스크는 시작할 때 읽은 값을 쓰므로, 바꾼 뒤에는 그 서비스를 다시 배포한다.
# 읽기 전용 역할은 KMS 복호화 권한이 없어 이 스택은 Atlantis 나 관리자만 plan 할 수 있다.

# ephemeral 로 풀어 상태 파일에 평문이 남지 않는다
ephemeral "sops_file" "service" {
  for_each = local.secret_files

  source_file = each.value
  input_type  = "yaml"
}

resource "aws_secretsmanager_secret" "service" {
  for_each = local.secret_files

  name                    = "${local.name_prefix}/app/${local.services[each.key].name}"
  description             = "Secrets for ${local.services[each.key].name}. Keys: ${join(", ", local.secret_keys[each.key])}"
  recovery_window_in_days = 7

  tags = {
    Name    = "${local.name_prefix}/app/${local.services[each.key].name}"
    Service = local.services[each.key].name
  }
}

resource "aws_secretsmanager_secret_version" "service" {
  for_each = local.secret_files

  secret_id = aws_secretsmanager_secret.service[each.key].id

  # write-only 라 값이 상태 파일에 남지 않는다. 파일 해시로 버전을 정해 암호문이 바뀔 때만 다시 쓴다.
  # 해시 앞 13자리(52비트)를 쓴다. 상태 파일은 숫자를 float64 로 담아 2^53 을 넘으면 끝자리가 뭉개지고,
  # 그러면 plan 마다 버전이 달라 보여 매번 다시 쓴다(15자리일 때 그랬다).
  # sops 는 다시 암호화할 때마다 암호문이 바뀌므로, 값이 같아도 재암호화하면 한 번 다시 쓴다
  secret_string_wo         = jsonencode(ephemeral.sops_file.service[each.key].data)
  secret_string_wo_version = parseint(substr(filesha256(each.value), 0, 13), 16)
}
