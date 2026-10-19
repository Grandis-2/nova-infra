# 부하 시험(Grandis-2/nova-loadtest) 헤더. 이 값을 x-nova-loadtest 로 보낸 요청은 요청 제한(ApiRateLimit · QueueRateLimit)만
# 건너뛴다. 관리형 규칙 · 본문 상한 · 패턴 규칙은 그대로 받는다. k6 는 공인 IP 몇 개에서 초당 수백~수천 건을 보내므로
# 이 예외가 없으면 IP 당 5분 3,000회에 바로 막힌다.
#
# 값은 secretsmanager 스택이 만든다(nova-prod/ops/loadtest/header, ephemeral 로 쓰기 전용). 여기서 읽으므로 값이 이 스택 상태에 남고,
# WAF 콘솔의 샘플 요청에도 보인다. 의심되면 secret_versions["ops/loadtest-header"] 를 올리고 secretsmanager → edge 순서로 적용한다.
# 그 사이에는 k6 가 옛 값을 보내 막히므로 시험을 하지 않는다.
data "aws_secretsmanager_secret_version" "loadtest_header" {
  secret_id = "${local.name_prefix}/ops/loadtest/header"
}

locals {
  loadtest_header = data.aws_secretsmanager_secret_version.loadtest_header.secret_string
}
