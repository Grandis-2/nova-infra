# ─────────────────────────────────────────────────────────────
# OTel Java 에이전트 — 로그 · 트레이스 · 지표를 OTel 게이트웨이(monitoring 스택 gateway.tf)로 보낸다 (NV-425, NV-543)
#
# jar 은 be 이미지 /otel/javaagent.jar 에 있다 (be NV-356). 켜는 것은 JDK_JAVA_OPTIONS 의 -javaagent 하나다(locals.tf jvm_options).
#   JAVA_TOOL_OPTIONS 는 주지 않는다. 이미지가 그 변수에 힙 옵션(MaxRAMPercentage 등)을 넣어 두어서, 여기서 주면 덮여 사라진다.
#   JDK_JAVA_OPTIONS 는 이미지가 쓰지 않는 변수라 겹치지 않는다. 없으면 jar 자체가 로드되지 않는다.
#   이미지의 AOT 캐시는 학습 · 실행 모두 --add-modules=java.instrument 로 맞춰 두어 에이전트를 켜도 쓰인다.
#
# 받는 곳은 Service Connect 별칭 otel-gateway.<네임스페이스> 다. 게이트웨이가 obs 의 Loki · Tempo · Mimir 로 넘긴다.
# 게이트웨이는 obs 와 따로 배포돼 obs 재배포 동안에도 받는다. Service Connect 별칭은 태스크가 뜰 때 정해지므로
# 앱 태스크가 게이트웨이보다 먼저 떠 있었다면 다시 띄워야 풀린다(이 값이 바뀌면 모든 서비스가 다시 뜬다).
# 프로토콜과 포트는 짝이다(4318 = http/protobuf, 4317 = grpc). 어긋나면 앱 로그에 한 줄만 남고 아무것도 도착하지 않는다.
#
# 기동 시간: 계측을 전부 켜면 캐시가 있어도 약 17.5–20초(로컬, preorder, 1 vCPU). 에이전트 없이 약 8–9초.
# ALB 헬스체크 유예(모듈 기본 120초) 안에 든다.
# ─────────────────────────────────────────────────────────────

locals {
  otel_all      = contains(var.otel_services, "*")
  otel_enabled  = { for k, v in local.deployed_services : k => local.otel_all || contains(var.otel_services, k) }
  otel_unknown  = [for k in var.otel_services : k if k != "*" && !contains(keys(local.services), k)]
  otel_endpoint = "http://otel-gateway.${var.namespace_name}:4318"

  # 프로파일(NV-540). service.yml 의 profiling: true 인 서비스만. 확장 jar 를 OTel 에이전트가 읽어
  # Pyroscope(obs, Service Connect pyroscope.<네임스페이스>)로 보낸다. 받는 쪽은 lgtm 스택의 pyroscope 컨테이너다.
  # 스팬 ID 를 프로파일에 붙여 Grafana 에서 느린 스팬 → 그동안의 플레임 그래프로 간다.
  # Fargate 는 perf_events 를 막아 CPU 는 itimer 로 받는다. 할당 · 락 프로파일은 그대로 된다.
  # 한 서비스씩 켜서 CPU · 메모리 증가를 잰 뒤 넓힌다
  profiling_env = {
    for k, v in local.deployed_services : k => local.otel_enabled[k] && v.profiling ? {
      OTEL_JAVAAGENT_EXTENSIONS      = "/otel/pyroscope-otel.jar"
      OTEL_PYROSCOPE_START_PROFILING = "true"
      PYROSCOPE_APPLICATION_NAME     = v.name
      PYROSCOPE_SERVER_ADDRESS       = "http://pyroscope.${var.namespace_name}:4040"
      PYROSCOPE_LABELS               = "service_namespace=nova,deployment_environment=${var.env}"
      PYROSCOPE_PROFILER_EVENT       = "itimer"
      PYROSCOPE_FORMAT               = "jfr"
      PYROSCOPE_PROFILER_ALLOC       = "512k"
      PYROSCOPE_PROFILER_LOCK        = "10ms"
      PYROSCOPE_UPLOAD_INTERVAL      = "15s"
    } : {}
  }

  otel_env = {
    for k, v in local.deployed_services : k => local.otel_enabled[k] ? {
      OTEL_SERVICE_NAME           = v.name
      OTEL_RESOURCE_ATTRIBUTES    = "deployment.environment=${var.env},service.namespace=nova"
      OTEL_EXPORTER_OTLP_ENDPOINT = local.otel_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      OTEL_TRACES_EXPORTER        = "otlp"
      # 지표 전송만 끄는 스위치(otel_metrics_enabled). 받는 쪽은 lgtm 스택의 Mimir 다
      OTEL_METRICS_EXPORTER = var.otel_metrics_enabled ? "otlp" : "none"
      OTEL_LOGS_EXPORTER    = "otlp"
      # 샘플링은 수집기(tail sampling)가 한다. 여기서 자르면 버려진 쪽의 오류 트레이스를 다시 찾을 수 없다
      OTEL_TRACES_SAMPLER = "parentbased_always_on"
      # 기존 Micrometer 지표(Resilience4j 등)도 같이 보낸다
      OTEL_INSTRUMENTATION_MICROMETER_ENABLED = "true"
      # SQS 메시지 속성에 trace context 를 실어 큐 너머까지 트레이스를 잇는다 (속성 10개 한도 안: eventType · eventId + traceparent)
      OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING = "true"
      # logback key-value 중 업무 식별자만 속성으로 (2.32.0 의 새 이름. 이름 목록을 받고 true 는 받지 않는다)
      OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED = "event_id,aggregate_type,aggregate_id,event_type,destination"
      # MDC 는 요청 ID(traceId)만. subject(회원 ID)는 받지 않는다
      OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED = "traceId"
      # 동시 처리 중인 요청 수(http.server.active_requests). 같은 스위치로 켜지는 본문 크기 히스토그램은 Collector 가 버린다
      OTEL_INSTRUMENTATION_HTTP_SERVER_EMIT_EXPERIMENTAL_TELEMETRY = "true"
      # CloudFront 요청 ID · ALB 추적 ID 를 서버 스팬 속성(http.request.header.*)으로 남긴다. 트레이스를 엣지 접근 로그와 잇는 키다.
      # 클라이언트가 보낸 값이 섞일 수 있어 Collector(lgtm 스택 collector.yaml 의 transform/mask-spans)가 AWS 형식만 남긴다
      OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS = "x-amz-cf-id,x-amzn-trace-id"
    } : {}
  }
}

resource "terraform_data" "otel_check" {
  lifecycle {
    precondition {
      condition     = length(local.otel_unknown) == 0
      error_message = "otel_services 에 없는 서비스 키: ${join(", ", local.otel_unknown)}"
    }
    precondition {
      condition     = alltrue([for k, v in local.deployed_services : !v.profiling || local.otel_enabled[k]])
      error_message = "profiling: true 인 서비스는 otel_services 에도 있어야 한다(확장은 OTel 에이전트가 읽는다)."
    }
  }
}
