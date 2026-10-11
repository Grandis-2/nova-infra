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
  _cfg_empty = [for k, t in local._cfg_text : k if try(yamldecode(t), null) == null]

  # 인프라가 정하는 값. yml 보다 우선한다
  _cfg_computed = {
    for k, v in local.deployed_services : k => merge(
      { "spring.application.name" = v.name },
      v.port > 0 ? { "server.port" = tostring(v.port) } : {},
      # Kubernetes 밖에서는 이 플래그가 있어야 Boot 가 liveness/readiness 그룹을 연다
      v.mgmt_port > 0 ? {
        "management.server.port"                    = tostring(v.mgmt_port)
        "management.endpoint.health.probes.enabled" = "true"
      } : {},
      v.db != null ? { "spring.datasource.url" = "jdbc:mysql://${local.db_address}:${local.db_port}/${v.db}?${local.jdbc_params}" } : {},
      { for db, prefix in v.extra_databases : "${prefix}.url" => "jdbc:mysql://${local.db_address}:${local.db_port}/${db}?${local.jdbc_params}" },
      v.redis != null ? {
        "spring.data.redis.host"        = local.redis_endpoints[v.redis]
        "spring.data.redis.port"        = tostring(local.redis_ports[v.redis])
        "spring.data.redis.ssl.enabled" = "true" # 전송 구간 암호화를 켠 클러스터다
      } : {},
      # 리전만 준다. 엔드포인트를 지정하지 않아야 태스크 역할로 SQS 에 붙는다
      length(concat(v.queues.send, v.queues.consume, v.queues.dlq)) > 0 ? {
        "nova.sqs.region"                = var.aws_region
        "spring.cloud.aws.region.static" = var.aws_region
      } : {},
      # JWKS 를 Cloud Map 주소(http)로 받는다. https 가 아니면 앱이 이 플래그를 요구한다
      v.jwt == "verify" ? {
        "jwt.jwk-set-uri"        = "${local.service_urls["member"]}/.well-known/jwks.json"
        "jwt.jwk-set-allow-http" = "true"
      } : {},
      { for p, to in v.calls : p => local.service_urls[to] },
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

  # localhost 주소가 남아 있으면 운영에서 연결이 실패한다
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
      condition     = length(local._cfg_local_values) == 0
      error_message = "application.yml 에 로컬 주소가 남아 있다: ${join(", ", local._cfg_local_values)}"
    }
    precondition {
      condition     = length(local._secret_missing) == 0
      error_message = "secrets.sops.yml · generated_secrets 가 있는데 시크릿이 아직 없다: ${join(", ", local._secret_missing)}. secretsmanager 스택을 먼저 apply 한다."
    }
    precondition {
      condition     = length(local._secret_reserved) == 0
      error_message = "비밀(secrets.sops.yml · generated_secrets) 키가 인프라 환경변수나 service.yml 의 environment 와 겹친다: ${join(", ", local._secret_reserved)}"
    }
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
