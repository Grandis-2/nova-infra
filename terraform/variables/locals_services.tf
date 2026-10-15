# 서비스 목록. terraform/application/<서비스>/service.yml 을 읽는다.
# 서비스 추가·수정은 이 파일이 아니라 application/ 에서 한다.
# ECR, IAM, securitygroup, ncp database, ECS, scheduler 스택이 함께 쓴다.
locals {
  # 스택 경로(…/terraform/<aws|ncp>/…)를 기준으로 terraform/application 을 찾는다
  application_dir = (
    var.application_dir != ""
    ? var.application_dir
    : "${regex("^(.*)/terraform/(?:aws|ncp)/", "${abspath(path.root)}/")[0]}/terraform/application"
  )

  _service_raw = {
    for f in fileset(local.application_dir, "*/service.yml") :
    dirname(f) => yamldecode(file("${local.application_dir}/${f}"))
    if !startswith(dirname(f), "_")
  }

  # 모든 서비스의 ALB 규칙 우선순위 (겹치면 ALB 가 거절한다)
  _all_priorities = flatten([for k, s in local._service_raw : [for r in try(s.routes, []) : try(r.priority, -1)]])

  _service_fields = [
    "name", "deploy", "image_tag", "cpu", "memory", "port", "management_port", "deployment", "spot", "stop_timeout", "scaling",
    "health", "routes", "jwt", "calls", "db", "extra_databases", "redis", "queues", "uploads", "generated_secrets", "environment",
    "profiling",
  ]

  # 형식 검사. 오류가 있으면 services.name 계산에서 해당 폴더 이름과 함께 plan 을 멈춘다
  _service_errors = {
    for k, s in local._service_raw : k => compact(flatten([
      can(keys(s)) ? "" : "YAML 맵이 아님",
      [for f in try(keys(s), []) : contains(local._service_fields, f) ? "" : "모르는 필드 '${f}'"],
      [for f in ["cpu", "memory", "port"] : can(tonumber(s[f])) ? "" : "필수 필드 '${f}'(숫자) 없음"],
      can(regex("^(latest|[0-9a-f]{6,40})$", try(s.image_tag, "latest"))) ? "" : "image_tag 는 latest 또는 커밋 해시 앞 6자리 이상(소문자 16진수)",
      # 따옴표 없이 쓴 숫자뿐인 해시(0123456)는 YAML 이 숫자로 읽어 앞자리 0 이 사라진다
      startswith(jsonencode(try(s.image_tag, "latest")), "\"") ? "" : "image_tag 는 따옴표로 감싼다 (예: image_tag: \"0123456\")",
      [for r in try(s.routes, []) : can(tonumber(r.priority)) && can(length(r.paths)) ? "" : "route 마다 priority(숫자)와 paths(목록)가 필요"],
      contains(["rolling", "blue_green", "singleton"], try(s.deployment, "rolling")) ? "" : "deployment 는 rolling | blue_green | singleton",
      contains(["sign", "verify", "none"], try(s.jwt, "none")) ? "" : "jwt 는 sign | verify | none",
      # 오타(treu) · 문자열("true")이 조용히 false 가 되지 않게 YAML 불리언만 받는다. 비우면(null) false
      contains(["true", "false", "null"], jsonencode(try(s.profiling, false))) ? "" : "profiling 은 true | false",
      try(s.deployment, "rolling") != "blue_green" || length(try(s.routes, [])) > 0 ? "" : "blue_green 은 routes 가 필요",
      length(try(s.routes, [])) == 0 || can(tonumber(s.health.port)) ? "" : "routes 가 있으면 health(port, path) 가 필요",
      [for r in try(s.routes, []) : length(try(r.paths, [])) + length(try(r.methods, [])) <= 4 ? "" : "route ${try(r.priority, "?")}: paths + methods 는 4개 이하"],
      # Fargate 의 stopTimeout 상한은 120초다
      try(s.stop_timeout, null) == null || (can(tonumber(s.stop_timeout)) && try(tonumber(s.stop_timeout) >= 2 && tonumber(s.stop_timeout) <= 120, false)) ? "" : "stop_timeout 은 2~120(초)",
      can(s.scaling.backlog.queue) && can(s.scaling.backlog.queues) ? "scaling.backlog 에는 queue 와 queues 중 하나만 쓴다" : "",
      # 틀린 모양이면 backlog 가 조용히 빠져 큐 적체로 늘지 않는다. 그래서 여기서 멈춘다
      try(s.scaling.backlog, null) == null || (
        (can(tostring(s.scaling.backlog.queue)) || try(length([for q in s.scaling.backlog.queues : tostring(q)]) >= 1 && length(s.scaling.backlog.queues) <= 8, false))
        && try(tonumber(s.scaling.backlog.per_task) > 0, false)
      ) ? "" : "scaling.backlog 는 queue(문자열) 또는 queues(1~8개 목록)와 per_task(0 보다 큰 수)가 필요",
      # 컨테이너 헬스체크(routes 없음)는 200 만 본다. ALB 처럼 범위(200-299)를 쓰지 않는다
      length(try(s.routes, [])) > 0 || try(s.health, null) == null || try(tostring(s.health.matcher), "200") == "200" ? "" : "routes 없이 쓰는 health 의 matcher 는 200 만 된다",
      # 컨테이너 헬스체크 명령(bash)에 그대로 들어가므로 경로 문자를 제한한다
      try(s.health, null) == null || can(regex("^/[A-Za-z0-9/._-]*$", tostring(s.health.path))) ? "" : "health.path 는 /로 시작하고 영문 · 숫자 · / . _ - 만 쓴다",
      [for p, to in try(s.calls, {}) : contains(keys(local._service_raw), to) ? "" : "calls 의 '${to}' 는 없는 서비스"],
      [for p, to in try(s.calls, {}) : try(tonumber(local._service_raw[to].port), 0) > 0 ? "" : "calls 의 '${to}' 는 포트가 없는 서비스(port: 0)"],
      [for r in try(s.routes, []) : can(tonumber(r.priority)) && length([for x in local._all_priorities : x if x == try(r.priority, -1)]) > 1 ? "route priority ${try(r.priority, "?")} 가 다른 규칙과 겹침" : ""],
      [for e in try(local.secret_keys[k], []) : can(regex("^[A-Z_][A-Z0-9_]*$", e)) ? "" : "secrets.sops.yml 의 키 '${e}' 는 환경변수 이름(대문자, 숫자, _)이어야 함"],
      [for e, t in try(s.generated_secrets, {}) : can(regex("^[A-Z_][A-Z0-9_]*$", e)) ? "" : "generated_secrets 의 키 '${e}' 는 환경변수 이름이어야 함"],
      [for e, t in try(s.generated_secrets, {}) : can(regex("^(rsa-2048|random-48|admin-bcrypt|shared/[a-z0-9-]+)$", t)) ? "" : "generated_secrets 의 ${e}: rsa-2048 | random-48 | admin-bcrypt | shared/<이름> 중 하나여야 함"],
      [for e, t in try(s.generated_secrets, {}) : contains(try(local.secret_keys[k], []), e) ? "'${e}' 가 generated_secrets 와 secrets.sops.yml 에 둘 다 있음" : ""],
    ]))
  }

  services = {
    for k, s in local._service_raw : k => {
      name = (
        length(local._service_errors[k]) > 0
        ? tostring(tonumber("application/${k}/service.yml — ${join(" · ", local._service_errors[k])}"))
        : try(tostring(s.name), k)
      )
      deploy    = try(tobool(s.deploy), true)
      image_tag = try(tostring(s.image_tag), "latest") # latest 또는 커밋 해시 앞자리 (ecs 가 전체 태그 · 다이제스트로 찾는다)
      # 값이 없으면 형식 검사에서 이미 멈추므로 여기서는 오류를 또 내지 않는다
      cpu        = try(tonumber(s.cpu), 0)
      memory     = try(tonumber(s.memory), 0)
      port       = try(tonumber(s.port), 0)
      mgmt_port  = try(tonumber(s.management_port), 0)
      blue_green = try(s.deployment, "rolling") == "blue_green"
      singleton  = try(s.deployment, "rolling") == "singleton"
      spot       = try(tobool(s.spot), true)
      # 프로파일(Pyroscope, NV-540)을 보낸다. 이미지에 확장 jar(/otel/pyroscope-otel.jar)가 있어야 한다.
      # ecs 스택이 환경 변수를, securitygroup 스택이 obs 4040 인바운드를 이 값으로 만든다
      profiling = try(s.profiling, false) == true
      # SIGTERM 뒤 SIGKILL 까지 기다리는 시간(초). 비우면 ECS 기본값(30초). 정상 종료에 오래 걸리는 컨슈머만 늘린다
      stop_timeout = try(tonumber(s.stop_timeout), null)

      desired    = try(tonumber(s.scaling.desired), 1)
      min        = try(tonumber(s.scaling.min), try(tonumber(s.scaling.desired), 1))
      max        = try(tonumber(s.scaling.max), try(tonumber(s.scaling.min), try(tonumber(s.scaling.desired), 1)))
      cpu_target = try(tonumber(s.scaling.cpu_target), 60)
      # queue(하나) 또는 queues(여럿). 여럿이면 메시지 수를 더해 본다
      backlog = try({
        queues   = try([tostring(s.scaling.backlog.queue)], [for q in s.scaling.backlog.queues : tostring(q)])
        per_task = tonumber(s.scaling.backlog.per_task)
      }, null)

      health = try({
        port    = tonumber(s.health.port)
        path    = tostring(s.health.path)
        matcher = try(tostring(s.health.matcher), "200")
      }, null)
      routes = [for r in try(s.routes, []) : {
        priority = try(tonumber(r.priority), -1) # 빠지면 위 검사가 폴더 이름과 함께 알린다
        paths    = [for p in try(r.paths, []) : tostring(p)]
        methods  = [for m in try(r.methods, []) : tostring(m)]
      }]

      jwt             = try(tostring(s.jwt), "none")
      calls           = { for p, to in try(s.calls, {}) : p => tostring(to) } # Spring 속성 -> 서비스 키
      db              = try(tostring(s.db), null)
      extra_databases = { for db, prefix in try(s.extra_databases, {}) : db => tostring(prefix) }
      redis           = try(tostring(s.redis), null)
      queues = {
        send    = [for q in try(s.queues.send, []) : tostring(q)]
        consume = [for q in try(s.queues.consume, []) : tostring(q)]
        dlq     = [for q in try(s.queues.dlq, []) : tostring(q)]
        # 재시도해도 같은 확정 거절을 받은 메시지를 바로 넣을 DLQ. 본 큐 이름으로 적는다
        dlq_send = [for q in try(s.queues.dlq_send, []) : tostring(q)]
      }
      generated_secrets = { for e, t in try(s.generated_secrets, {}) : e => tostring(t) } # 환경변수 -> 만드는 방식
      uploads           = try(tobool(s.uploads), false)                                   # 이미지 업로드 버킷 쓰기 권한
      environment       = { for e, v in try(s.environment, {}) : e => tostring(v) }
    }
  }

  # 서비스 비밀 — application/<서비스>/secrets.sops.yml. sops 는 값만 암호화하고 키는 평문으로 둔다.
  # 그래서 복호화 없이 키 이름(= 컨테이너 환경변수 이름)을 읽는다. 값은 secretsmanager 스택이 apply 때 푼다
  secret_files = {
    for f in fileset(local.application_dir, "*/secrets.sops.yml") :
    dirname(f) => "${local.application_dir}/${f}"
    if !startswith(dirname(f), "_")
  }
  secret_keys = {
    for k, f in local.secret_files : k => sort([for key in keys(yamldecode(file(f))) : key if key != "sops"])
  }

  # Terraform 이 만드는 비밀 (service.yml 의 generated_secrets). 키마다 시크릿 하나라 서로 영향이 없다
  #   "<서비스>/<키>" -> 방식 (shared/<이름> 은 공유 시크릿을 참조하므로 여기서 뺀다)
  generated_secrets = merge([
    for k, v in local.services : { for e, t in v.generated_secrets : "${k}/${e}" => t if !startswith(t, "shared/") }
  ]...)
  # 공유 비밀 이름 (shared/<이름>) — 한 번만 만들고 여러 서비스가 같은 시크릿을 읽는다
  shared_secrets = toset(flatten([
    for k, v in local.services : [for e, t in v.generated_secrets : trimprefix(t, "shared/") if startswith(t, "shared/")]
  ]))

  # ECS 서비스로 띄울 대상. deploy: false 면 ECR, 역할, DB 계정만 만든다
  deployed_services = { for k, v in local.services : k => v if v.deploy }

  # ALB 타깃 그룹이 필요한 서비스
  alb_services = { for k, v in local.services : k => v if length(v.routes) > 0 }

  # ALB 규칙을 (서비스, 순번) 단위로 펼친다
  alb_routes = merge([
    for k, v in local.alb_services : {
      for i, r in v.routes : "${k}-${i}" => merge(r, { service = k })
    }
  ]...)

  # 실제 호출 대상. JWT 검증 서비스는 JWKS 를 받으려고 member 도 호출한다
  effective_calls = {
    for k, v in local.services :
    k => distinct(concat(values(v.calls), v.jwt == "verify" ? ["member"] : []))
  }

  # (호출자, 피호출자) 쌍. SG 인바운드 규칙을 여기서 만든다
  service_calls = merge([
    for caller, callees in local.effective_calls : {
      for callee in callees : "${caller}-to-${callee}" => {
        caller = caller
        callee = callee
      }
    }
  ]...)
}
