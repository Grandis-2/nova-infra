# 부하 시험 헤더(x-nova-loadtest) 값. 이 값을 보낸 요청은 WAF 요청 제한(ApiRateLimit · QueueRateLimit)만 건너뛴다.
# edge 스택이 읽어 WAF 규칙에 넣고, 부하 시험 실행 역할(terraform/aws/loadtest 스택)이 읽어 k6 에 넣는다.
# ops/* 라 서비스(공용 실행 역할)는 읽지 못한다.
#
# generated.tf 와 같이 ephemeral 로 만들어 쓰기 전용으로 넣는다(이 스택 상태에는 값이 남지 않는다).
# secret_versions["ops/loadtest-header"] 를 올리면 새 값이 된다. 그 뒤 edge 를 적용해야 WAF 규칙이 따라가므로 그 사이에는 시험을 하지 않는다.
# WAF 헤더 비교에 그대로 넣으므로 영문 · 숫자만 쓴다.

locals {
  loadtest_header_version_key = "ops/loadtest-header"
}

ephemeral "random_password" "loadtest_header" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "loadtest_header" {
  name                    = "${local.name_prefix}/ops/loadtest/header"
  description             = "Load test header value (x-nova-loadtest). Skips WAF rate limits only"
  recovery_window_in_days = 7

  tags = { Service = "loadtest" }
}

resource "aws_secretsmanager_secret_version" "loadtest_header" {
  secret_id                = aws_secretsmanager_secret.loadtest_header.id
  secret_string_wo         = ephemeral.random_password.loadtest_header.result
  secret_string_wo_version = local.version_of[local.loadtest_header_version_key]
}
