# ─────────────────────────────────────────────────────────────
# 앱 설정 — application/<서비스>/application.yml + 인프라 계산값 → SPRING_APPLICATION_JSON
#
# 이미지에는 설정 파일이 없고, 이 값이 컨테이너가 받는 설정 전부다.
# 태스크 정의 환경변수로 들어가므로 설정을 바꾸면 apply 가 새 리비전으로 배포한다.
# 비밀 값은 넣지 않는다. application/<서비스>/secrets.sops.yml → Secrets Manager → 환경변수 (locals.tf 의 service_secrets).
#
# 계산값은 점이 든 키("spring.datasource.url")로 최상위에 둔다. jsonencode 는 키를 사전순으로 써서
# "spring" 블록 뒤에 "spring.…" 가 오고, Spring 은 같은 키면 뒤의 값을 쓴다 → 계산값이 항상 yml 을 덮는다.
# ─────────────────────────────────────────────────────────────

locals {
  # 서비스 -> application.yml 원문 (없으면 빈 문자열)
  _cfg_text = {
    for k, v in local.deployed_services : k => (
      fileexists("${local.application_dir}/${k}/application.yml") ? file("${local.application_dir}/${k}/application.yml") : ""
    )
  }
  # 주석뿐(null)이거나 빈 맵({})이면 비어 있는 것으로 본다
  _cfg_empty = [for k, t in local._cfg_text : k if try(length(yamldecode(t)), 0) == 0]

  # 인프라가 정하는 값. yml 보다 우선한다
  _cfg_computed = {
    for k, v in local.deployed_services : k => merge(
      { "spring.application.name" = v.name },
      # 콘솔(→ CloudWatch Logs) 로그를 ECS JSON 한 줄로 찍는다. 스택트레이스가 한 이벤트(error.stack_trace)에 들어가고
      # MDC · key-value 가 필드가 되어 Logs Insights 로 바로 거른다. service.name 은 spring.application.name 이다.
      # 로컬 실행에는 들어가지 않으므로 사람이 읽는 텍스트 로그는 그대로다.
      { "logging.structured.format.console" = "ecs" },
      v.port > 0 ? { "server.port" = tostring(v.port) } : {},
      # Kubernetes 밖에서는 이 플래그가 있어야 Boot 가 liveness/readiness 그룹을 연다
      v.mgmt_port > 0 ? {
        "management.server.port"                    = tostring(v.mgmt_port)
        "management.endpoint.health.probes.enabled" = "true"
      } : {},
      v.db != null ? { "spring.datasource.url" = "jdbc:mysql://${local.app_db_address}:${local.app_db_port}/${v.db}?${local.jdbc_params}" } : {},
      { for db, prefix in v.extra_databases : "${prefix}.url" => "jdbc:mysql://${local.app_db_address}:${local.app_db_port}/${db}?${local.jdbc_params}" },
      v.redis != null ? {
        "spring.data.redis.host"        = local.redis_endpoints[v.redis]
        "spring.data.redis.port"        = tostring(local.redis_ports[v.redis])
        "spring.data.redis.ssl.enabled" = "true" # 전송 구간 암호화를 켠 클러스터다
      } : {},
      # 리전만 준다. 엔드포인트를 지정하지 않아야 태스크 역할로 SQS 에 붙는다
      length(concat(v.queues.send, v.queues.consume, v.queues.dlq, v.queues.dlq_send)) > 0 ? {
        "nova.sqs.region"                = var.aws_region
        "spring.cloud.aws.region.static" = var.aws_region
      } : {},
      # JWKS 를 Cloud Map 주소(http)로 받는다. https 가 아니면 앱이 이 플래그를 요구한다
      v.jwt == "verify" ? {
        "jwt.jwk-set-uri"        = "${local.service_urls["member"]}/.well-known/jwks.json"
        "jwt.jwk-set-allow-http" = "true"
      } : {},
      { for p, to in v.calls : p => local.service_urls[to] },
      # 이미지 업로드 버킷. catalog 는 여기에 올리고 조회 URL 을 CDN 주소 + 키로 만든다. 정리 배치는 같은 버킷에서 지운다
      v.uploads || v.upload_cleanup ? {
        "nova.upload.bucket"       = data.terraform_remote_state.s3.outputs.upload_bucket.id
        "nova.upload.cdn-base-url" = data.terraform_remote_state.cdn.outputs.image_base_url
        "nova.upload.region"       = var.aws_region
      } : {},
    )
  }

  # 서비스 -> SPRING_APPLICATION_JSON
  service_config_json = {
    for k, v in local.deployed_services : k => jsonencode(merge(
      try(yamldecode(local._cfg_text[k]), {}), # 주석뿐이면 null → merge 가 무시한다
      local._cfg_computed[k],
    ))
  }

  # ── 검사 (원문 줄 단위, 주석 줄 제외) ─────────────────────
  # 비밀처럼 보이는 키에는 자리표시(${ENV})만 허용한다. SPRING_APPLICATION_JSON 이 환경변수보다
  # 우선하므로, 실제 값을 적으면 Secrets Manager 에서 넣은 값을 덮어 버린다.
  _cfg_secret_literals = flatten([
    for k, text in local._cfg_text : [
      for m in regexall("(?m)^\\s*([A-Za-z0-9_.-]*(?i:password|secret|private-?key|access-?key|credentials)[A-Za-z0-9_.-]*)\\s*:[ \\t]*([^\\s#].*)$", text) :
      "${k}: ${m[0]}" if !startswith(trimspace(m[1]), "$${") && !startswith(trimspace(m[1]), "\"$${")
    ]
  ])

  # localhost 주소가 남아 있으면 운영에서 연결이 실패한다. 로컬 개발용으로 일부러 넣는 값(카카오 리다이렉트 등)이 있어
  # plan 을 막지 않고 경고(check)만 남긴다
  _cfg_local_values = flatten([
    for k, text in local._cfg_text : [
      for m in regexall("(?m)^\\s*([^#\\s][^:]*):.*(?:localhost|127\\.0\\.0\\.1)", text) : "${k}: ${trimspace(m[0])}"
    ]
  ])
}

locals {
  # 비밀 파일은 있는데 secretsmanager 스택이 아직 시크릿을 만들지 않은 서비스
  _secret_missing = concat(
    [for k in keys(local.deployed_services) : k if length(lookup(local.secret_keys, k, [])) > 0 && !contains(keys(local.app_secret_arns), k)],
    flatten([for k, v in local.deployed_services : [
      for e, t in v.generated_secrets : "${k}/${e}"
      if !(startswith(t, "shared/") ? contains(keys(local.shared_secret_arns), trimprefix(t, "shared/")) : contains(keys(local.generated_secret_arns), "${k}/${e}"))
    ]]),
  )

  # 인프라가 직접 넣는 환경변수와 이름이 같으면 태스크 정의가 깨진다
  _reserved_env = ["SPRING_PROFILES_ACTIVE", "AWS_REGION", "SPRING_APPLICATION_JSON", "SPRING_DATASOURCE_USERNAME", "SPRING_DATASOURCE_PASSWORD"]
  _secret_reserved = flatten([
    for k in keys(local.deployed_services) : [
      for key in concat(lookup(local.secret_keys, k, []), keys(local.deployed_services[k].generated_secrets)) : "${k}: ${key}"
      if contains(local._reserved_env, key) || endswith(key, "_DATASOURCE_USERNAME") || endswith(key, "_DATASOURCE_PASSWORD") || contains(keys(local.deployed_services[k].environment), key)
    ]
  ])
}

# DB 연결 예산 — 서비스가 최대 대수까지 늘고 배포로 새 태스크가 함께 떠도(Rolling · Blue/Green 모두 잠깐 2배) 연결 합이
# RDS max_connections 를 넘지 않아야 한다. 넘으면 늘어난 태스크가 DB 에 붙지 못해 증설이 오히려 장애가 된다.
# 대수는 desired · min · max 중 큰 값(오토스케일링이 없으면 desired 로 뜬다). 풀 크기는 application.yml 의 maximum-pool-size
# (중첩 · 점 키)와 service.yml environment 덮어쓰기 중 큰 값, 아무것도 없으면 Hikari 기본값 10. db 가 있으면 실제로 안 붙는
# 서비스(worker)도 세어 넉넉하게 본다. max 를 올리거나 풀을 키우는 PR 이 이 검사에 걸리면 rds 의 max_connections 를 먼저 올린다
locals {
  _db_pool_size = {
    for k, v in local.deployed_services : k => max(concat([0], compact([
      try(tostring(tonumber(yamldecode(local._cfg_text[k]).spring.datasource.hikari["maximum-pool-size"])), null),
      try(tostring(tonumber(yamldecode(local._cfg_text[k])["spring.datasource.hikari.maximum-pool-size"])), null),
      try(tostring(tonumber(v.environment["SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE"])), null),
      try(tostring(tonumber(v.environment["SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE"])), null),
    ]))...)
  }
  _db_pool = {
    for k, v in local.deployed_services : k => max(v.desired, v.min, v.max) * (
      (v.db != null ? (local._db_pool_size[k] > 0 ? local._db_pool_size[k] : 10) : 0)
      + 10 * length(v.extra_databases)
    )
  }
  _db_conn_reserve = 50 # 사람 · 마이그레이션 · exporter · RDS 관리 연결
  _db_conn_need    = 2 * sum(concat([0], values(local._db_pool))) + local._db_conn_reserve
  # rds 스택을 apply 하기 전(출력 없음)에는 검사를 건너뛴다
  _db_conn_max = try(data.terraform_remote_state.database.outputs.max_connections, null)
}

resource "terraform_data" "config_check" {
  lifecycle {
    # deploy: true 인데 설정이 비어 있으면 인프라 계산값만 받고 기동에 실패한다
    precondition {
      condition     = length(local._cfg_empty) == 0
      error_message = "application.yml 이 비어 있는데 deploy: true 인 서비스: ${join(", ", local._cfg_empty)}. 설정을 채우거나 deploy: false 로 둔다."
    }
    precondition {
      condition     = length(local._cfg_secret_literals) == 0
      error_message = "application.yml 에 비밀 값이 있다: ${join(", ", local._cfg_secret_literals)}. 같은 폴더의 secrets.sops.yml 로 옮기고, 값 자리에는 $${환경변수} 를 쓴다."
    }
    precondition {
      condition     = length(local._secret_missing) == 0
      error_message = "secrets.sops.yml · generated_secrets 가 있는데 시크릿이 아직 없다: ${join(", ", local._secret_missing)}. secretsmanager 스택을 먼저 apply 한다."
    }
    precondition {
      condition     = length(local._secret_reserved) == 0
      error_message = "비밀(secrets.sops.yml · generated_secrets) 키가 인프라 환경변수나 service.yml 의 environment 와 겹친다: ${join(", ", local._secret_reserved)}"
    }
    precondition {
      condition     = local._db_conn_max == null || local._db_conn_need <= local._db_conn_max
      error_message = "DB 연결이 모자랄 수 있다: 최대 대수 × 풀 × 2(배포 중) + 여유 ${local._db_conn_reserve} = ${local._db_conn_need} > RDS max_connections ${coalesce(local._db_conn_max, 0)}. 서비스별(최대 대수 × 풀): ${join(", ", [for k, n in local._db_pool : "${k} ${n}" if n > 0])}. rds 스택의 max_connections 를 올리거나 scaling.max · maximum-pool-size 를 줄인다."
    }
  }
}

check "no_local_values" {
  assert {
    condition     = length(local._cfg_local_values) == 0
    error_message = "application.yml 에 로컬 주소가 있다(의도한 값인지 확인): ${join(", ", local._cfg_local_values)}"
  }
}

# 떠 있는 서비스가 부르는 서비스(calls, JWT 검증이면 member)가 deploy: false 면
# plan 은 통과하지만 실행 중에 그 호출이 실패한다. 미리 보이게 경고한다
locals {
  _missing_callees = flatten([
    for k, v in local.deployed_services : [
      for c in local.effective_calls[k] : "${k} → ${c}" if !contains(keys(local.deployed_services), c)
    ]
  ])
}

check "callees_deployed" {
  assert {
    condition     = length(local._missing_callees) == 0
    error_message = "부르는 서비스가 배포되지 않았다 (deploy: false): ${join(", ", local._missing_callees)}"
  }
}
