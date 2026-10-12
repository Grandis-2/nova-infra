# ─────────────────────────────────────────────────────────────
# OTel Java 에이전트 — 로그 · 트레이스 · 지표를 관측 스택(monitoring 스택의 obs 태스크)으로 보낸다 (NV-425)
#
# jar 은 be 이미지 /otel/javaagent.jar 에 있다 (be NV-356). 켜는 것은 JDK_JAVA_OPTIONS 하나다.
#   JAVA_TOOL_OPTIONS 는 주지 않는다. 이미지가 그 변수에 힙 옵션(MaxRAMPercentage 등)을 넣어 두어서, 여기서 주면 덮여 사라진다.
#   JDK_JAVA_OPTIONS 는 이미지가 쓰지 않는 변수라 겹치지 않는다. 없으면 jar 자체가 로드되지 않는다.
#   이미지의 AOT 캐시는 학습 · 실행 모두 --add-modules=java.instrument 로 맞춰 두어 에이전트를 켜도 쓰인다.
#
# 받는 곳은 Service Connect 별칭 otel.<네임스페이스> 다. 앱 태스크는 이미 Service Connect 클라이언트라 그대로 풀린다.
# 프로토콜과 포트는 짝이다(4318 = http/protobuf, 4317 = grpc). 어긋나면 앱 로그에 한 줄만 남고 아무것도 도착하지 않는다.
#
# 기동 시간: 계측을 전부 켜면 캐시가 있어도 약 17.5–20초(로컬, preorder, 1 vCPU). 에이전트 없이 약 8–9초.
# ALB 헬스체크 유예(모듈 기본 120초) 안에 든다.
# ─────────────────────────────────────────────────────────────

locals {
  otel_all      = contains(var.otel_services, "*")
  otel_enabled  = { for k, v in local.deployed_services : k => local.otel_all || contains(var.otel_services, k) }
  otel_unknown  = [for k in var.otel_services : k if k != "*" && !contains(keys(local.services), k)]
  otel_endpoint = "http://otel.${var.namespace_name}:4318"

  otel_env = {
    for k, v in local.deployed_services : k => local.otel_enabled[k] ? {
      JDK_JAVA_OPTIONS            = "-javaagent:/otel/javaagent.jar"
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
    } : {}
  }
}

resource "terraform_data" "otel_check" {
  lifecycle {
    precondition {
      condition     = length(local.otel_unknown) == 0
      error_message = "otel_services 에 없는 서비스 키: ${join(", ", local.otel_unknown)}"
    }
  }
}
