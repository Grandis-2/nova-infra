# lgtm — obs 태스크의 설정

nova 관측 스택(OTel Collector · Loki · Tempo · Mimir · Grafana)의 설정 파일이다. 로그 부분은 `Grandis-2/nova-observability` 에서 옮겨 왔다.
로그 · 트레이스 · 지표를 받는다.

이 폴더는 Terraform 이 읽지 않는다. 설정을 S3 에 올리고 ECS 작업 정의 · 서비스로 띄우는 것은 NV-434 에서 이 스택에 더한다.

```
앱 태스크 ──OTLP──▶ obs 태스크: otel-collector :4317/:4318 ─┬─ 로그 ──────────────▶ loki  :3100 ──▶ S3 (loki 버킷)
                                                          ├─ 트레이스(샘플링) ──▶ tempo :3200 ──▶ S3 (tempo 버킷)
                                                          └─ 지표 ─────────────▶ mimir :9009 ──▶ S3 (mimir 버킷)
                          mysqld_exporter :9104 ◀── Collector 가 긁음 (NCP DB 지표)
              loki · tempo · mimir · grafana /metrics ◀── Collector 가 긁음 (관측 스택 자신, 필요한 것만)
                          obs 호스트 /hostfs (읽기 전용) ◀── Collector hostmetrics (CPU · 메모리 · 디스크)
                                     grafana :3000 ── loki · tempo · mimir 조회   (ECS Exec 포트 포워딩으로만 접속)
```

obs 태스크의 컨테이너는 localhost 를 같이 쓴다(awsvpc). 포트가 겹치면 컨테이너가 죽는다.

| 컨테이너 | 포트 |
|---|---|
| otel-collector | 4317 (OTLP gRPC) · 4318 (OTLP HTTP) · 8888 (자체 지표, localhost) · 13133 (헬스체크) |
| loki | 3100 (HTTP) · 9096 (gRPC) |
| tempo | 3200 (HTTP) · 9097 (gRPC) · 14317 (OTLP gRPC 수신, localhost — Collector 만 보낸다) |
| mimir | 9009 (HTTP: OTLP 수신 `/otlp`, PromQL `/prometheus`) · 9098 (gRPC) · 7947 (memberlist, 127.0.0.1) |
| grafana | 3000 |
| mysqld_exporter | 9104 |

Tempo · Mimir 의 링은 메모리에 둔다. Tempo 는 memberlist 를 띄우지 않고, Mimir 3 는 띄우므로 7946 을 피해 127.0.0.1:7947 에 묶었다.

## 파일

| 경로 | 내용 |
|---|---|
| `collector.yaml` | Collector. 로그: `memory_limiter` → 리소스 허용 목록 → 저장 전 마스킹 → `batch` → Loki. 트레이스: `memory_limiter` → 리소스 허용 목록 → tail sampling → 스팬 마스킹 → `batch` → Tempo |
| `loki.yaml` | Loki 단일 바이너리. S3 저장, 보존 기간, 인덱스 라벨 지정, WAL, 삭제 요청 API 끔 |
| `tempo.yaml` | Tempo 단일 바이너리. S3 저장, 보존 기간(compactor), WAL, 정상 종료 때 블록 업로드 |
| `mimir.yaml` | Mimir 단일 바이너리(`-target=all`). S3 한 버킷에 블록 · ruler · alertmanager 를 접두사로, 보존 기간, 정상 종료 때 블록 업로드, OTLP 이름 접미사, 조회 대기열 1000 · 쿼리 샤딩 끔(한 대라 쪼개도 빨라지지 않는다) |
| `grafana/provisioning/datasources/` | Grafana 데이터소스: Loki(trace_id → Tempo 링크), Tempo(트레이스 → 로그), Mimir(exemplar → Tempo), CloudWatch(AWS 관리형 지표, 태스크 역할) |
| `grafana/provisioning/dashboards/nova.yaml` | 대시보드 프로비저닝. `/config/grafana/dashboards` 의 하위 디렉터리를 같은 이름의 Grafana 폴더로 읽는다(화면에서 고쳐도 저장되지 않고, 파일을 지우면 대시보드도 지워진다) |
| `grafana/dashboards/01 Overview/` | `overview.json` — 서비스 전체 현황(요청 수 · 5xx · P99 · 인스턴스 · 힙 · CPU 표, 경보 목록). 로그인 첫 화면 |
| `grafana/dashboards/10 Services/` | `service.json` — 서비스 상세 하나(`$service` 변수). HTTP · 외부 호출 · JVM · HikariCP · 로그 · 트레이스 |
| `grafana/dashboards/20 Data/` | `mysql.json`(NCP MySQL, Mimir · mysqld_exporter) · `valkey.json`(ElastiCache) · `sqs.json`(큐 · DLQ). Valkey · SQS 는 CloudWatch, 새로고침 5분 |
| `grafana/dashboards/30 Platform/` | `platform.json` — ECS 서비스(태스크 수 · 재시작 · CPU · 메모리), ALB(요청 · 오류 · 응답 시간 · 비정상 대상), CloudFront(us-east-1). CloudWatch, 새로고침 5분 |
| `grafana/dashboards/40 Troubleshooting/` | `troubleshooting.json` — 느린 경로 · 5xx 경로(지표), 느린 요청 · 오류 · 느린 DB 쿼리(트레이스), ERROR 로그 |
| `grafana/provisioning/alerting/` | 경보: `rules.yaml`(규칙 5개), `notify.yaml`(SNS 알림 대상 · 기본 경로 · Chatbot 템플릿) |
| `grafana/provisioning/plugins/` | 빈 프로비저닝 파일. 디렉터리가 없으면 Grafana 가 기동마다 오류 로그를 남긴다(S3 에는 빈 디렉터리가 없다) |

## 실행 환경이 넘길 값

설정 파일에는 실행 환경마다 다른 값이 없다. 아래를 컨테이너 환경 변수로 넘긴다.

| 컨테이너 | 변수 | 값 |
|---|---|---|
| otel-collector | `LOKI_OTLP_ENDPOINT` | `http://localhost:3100/otlp` |
| otel-collector | `TEMPO_OTLP_ENDPOINT` | `127.0.0.1:14317` (gRPC, TLS 없음. localhost 는 ::1 부터 붙어 실패 로그를 남긴다) |
| otel-collector | `MIMIR_OTLP_ENDPOINT` | `http://localhost:9009/otlp` |
| otel-collector | `MYSQLD_EXPORTER_TARGET` | `localhost:9104`. mysqld_exporter 를 띄우지 않으면 **빈 문자열** — 그때는 긁지 않는다 |
| otel-collector | `OBS_DATA_MOUNT_PATH` | `/data/obs` (ecs 스택 출력 `obs_data_mount_path`). hostmetrics 가 이 디스크와 루트의 사용률을 본다. 호스트 `/` 를 `/hostfs` 에 읽기 전용으로 붙인다 |
| loki | `LOKI_S3_BUCKET` · `LOKI_S3_REGION` | s3 스택 출력 `loki_bucket` 의 버킷, `ap-northeast-2` |
| loki | `LOKI_RETENTION_PERIOD` | `2160h` (90일). 조회 가능 범위(`max_query_lookback`)도 같은 값이다 |
| loki | `LOKI_S3_ENDPOINT` · `LOKI_S3_FORCE_PATH_STYLE` · `LOKI_S3_INSECURE` | 운영에서는 넘기지 않는다(S3 호환 저장소용) |
| loki | `LOKI_COMPACTION_INTERVAL` · `LOKI_RETENTION_DELETE_DELAY` | 운영에서는 넘기지 않는다(기본 10m · 2h) |
| tempo | `TEMPO_S3_BUCKET` · `TEMPO_S3_REGION` | s3 스택 출력 `tempo_bucket` 의 버킷, `ap-northeast-2` |
| tempo | `TEMPO_S3_ENDPOINT` | 넘기지 않는다. 없으면 `s3.<TEMPO_S3_REGION>.amazonaws.com` |
| tempo | `TEMPO_RETENTION` | `336h` (14일) |
| tempo | `TEMPO_S3_FORCE_PATH_STYLE` · `TEMPO_S3_INSECURE` | 운영에서는 넘기지 않는다(S3 호환 저장소용) |
| mimir | `MIMIR_S3_BUCKET` · `MIMIR_S3_REGION` | s3 스택 출력 `mimir_bucket` 의 버킷, `ap-northeast-2` |
| mimir | `MIMIR_RETENTION` | `2160h` (90일) |
| mimir | `MIMIR_S3_ENDPOINT` | 넘기지 않아도 된다. 없으면 `s3.ap-northeast-2.amazonaws.com` (Mimir 는 기본값 안에 다른 변수를 못 쓴다 — 리전을 바꾸면 넘긴다) |
| mimir | `MIMIR_S3_INSECURE` · `MIMIR_S3_BUCKET_LOOKUP_TYPE` | 운영에서는 넘기지 않는다(S3 호환 저장소용) |
| grafana | `LOKI_URL` · `TEMPO_URL` · `MIMIR_URL` | `http://localhost:3100` · `http://localhost:3200` · `http://localhost:9009/prometheus` |
| grafana | `GF_SECURITY_ADMIN_PASSWORD` | 비밀 주입: `nova-prod/ops/grafana/admin-password` (secretsmanager 스택) |
| grafana | `GF_PATHS_PROVISIONING` | `/config/grafana/provisioning` |
| grafana | `SNS_TOPIC_ARN` | **필수.** monitoring 스택의 알림 주제(Chatbot 이 구독). 비어 있으면 Grafana 가 뜨지 않는다(알림 대상 검증 실패) |
| grafana | `AWS_REGION` | `ap-northeast-2` (SNS 리전). 태스크 역할에 그 주제의 `sns:Publish` 가 있어야 한다 |

설정 파일은 컨테이너의 `/config/` 아래에 놓인다: `/config/collector.yaml` · `/config/loki.yaml` · `/config/tempo.yaml` · `/config/mimir.yaml` · `/config/grafana/**`.
Collector 는 `--config=/config/collector.yaml`, Loki · Tempo · Mimir 는 `-config.file=/config/<이름>.yaml -config.expand-env=true` 로 띄운다.

작업 정의(NV-434, `../main.tf`)가 지킬 것.
- 이미지는 태그와 다이제스트로 고정한다(`../main.tf` 의 `obs_images`).
- 데이터 경로는 재시작 · 인스턴스 교체에도 남는 디스크여야 한다(WAL): loki `/loki`, tempo `/var/tempo`, mimir `/data` (셋 다 UID 10001), grafana `/var/lib/grafana` (UID 472).
- Tempo · Mimir 이미지의 기본 사용자는 root 다. 작업 정의에서 `user: 10001:10001` 로 돌린다.
- Loki · Tempo · Mimir 의 정지 시간을 넉넉히 준다(`stopTimeout` 120초). 정상 종료 때 들고 있던 청크 · 블록을 S3 로 올린다.
- Collector 메모리는 1 GiB 이상. tail sampling 이 결정 전 트레이스를 메모리에 든다(`memory_limiter` 768 MiB).
- 버킷 정책은 `nova-prod-obs` 역할만 객체에 접근하게 막아 두었다(s3 스택).
- 모든 컨테이너는 리눅스 권한이 필요 없다(1024 위 포트만 쓴다). 권한을 모두 버리고 권한 상승을 막는다.

## 앱이 줄 값

에이전트는 be 이미지의 `/otel/javaagent.jar` 이다(NV-356). ecs 스택 `otel.tf` 가 변수 `otel_services` 에 든 서비스에 아래 값을 넣는다(지금은 `["*"]`, 배포 서비스 전부).

```
JDK_JAVA_OPTIONS=-javaagent:/otel/javaagent.jar
OTEL_SERVICE_NAME=<svc>
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.namespace=nova
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_TRACES_SAMPLER=parentbased_always_on
OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel.nova.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING=true
OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED=traceId
OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED=event_id,aggregate_type,aggregate_id,event_type,destination
```

- `JAVA_TOOL_OPTIONS` 는 주지 않는다. 이미지의 힙 옵션이 그 변수에 있어 덮으면 사라진다.
- 포트와 프로토콜은 짝을 맞춘다(`otel.nova.local:4318` 은 `http/protobuf`, gRPC 는 `otel-grpc.nova.local:4317`). 어긋나면 앱 로그에 실패 한 줄만 남고 아무것도 오지 않는다.
- logback 속성은 2.32.0 의 새 이름이다. 값은 `true` 가 아니라 이름 목록이다.
- MDC 는 `traceId`(요청 ID)만 받는다. `subject`(회원 ID)는 받지 않는다.
- 샘플링은 Collector 가 한다(`parentbased_always_on` 으로 모두 보낸다). 앱에서 자르면 버려진 쪽의 오류 트레이스를 다시 찾을 수 없다.

## 경보 (`grafana/provisioning/alerting/`)

Grafana 가 1분마다 Mimir 를 질의해 판단하고, SNS → AWS Chatbot → Slack 으로 보낸다. 같은 경보 이름 · job 끼리 묶고 4시간마다 다시 알린다.

| 규칙 | 조건 | 지속 | 등급 |
|---|---|---|---|
| HTTP 5xx 비율 | 서비스별 5xx 비율 > 5% | 5분 | critical |
| HTTP P99 응답 시간 | 서비스별 P99 > 2초 | 10분 | warning |
| JVM 힙 사용률 | 태스크별 힙 사용 / 한도 > 90% | 10분 | warning |
| 서비스 지표 끊김 | 지난 1시간 안에 보내던 서비스가 지금 target_info 를 안 보냄 | 5분 | critical |
| obs 수집 실패 | Collector 의 수신 거부 · 내보내기 실패 > 0 | 10분 | warning |

- 트래픽이 없어 질의가 비면 정상으로 본다(`noDataState: OK`). 질의가 실패하면 Grafana 가 오류 경보를 따로 보낸다.
- Chatbot 은 SNS 메시지가 사용자 지정 알림 JSON 일 때만 그대로 보여 준다. `notify.yaml` 의 템플릿이 그 JSON 을 만들고, 값의 `"` · `\` · 줄바꿈은 바꿔 넣는다.
- obs 자체가 죽으면 이 경보도 멈춘다. obs 태스크 · 인스턴스 감시는 CloudWatch 경보(작업 정의 쪽)가 맡는다.

## 트레이스 샘플링 (`collector.yaml` 의 `tail_sampling`)

트레이스가 끝나기를 10초 기다렸다가 정한다.

| 순서 | 조건 | 결정 |
|---|---|---|
| 1 | 헬스체크 서버 스팬(`url.path` 가 `/actuator/…`)이 있는 트레이스 | 버림 (오류여도) |
| 1 | 메시지 없이 끝난 SQS 롱폴링(`rpc.method=ReceiveMessage`, 메시지 수 없음 · 0, 오류 아님) | 버림 |
| 2 | 오류(ERROR) 스팬이 있는 트레이스 | 남김 |
| 2 | 1초 넘게 걸린 트레이스 | 남김 |
| 2 | 나머지 | 10% 남김 |

결정 전 트레이스는 메모리에 있다(최대 5만 건). 넘치면 오래된 것부터 결정 없이 버린다. 이 경로도 손실을 허용한다.

## 조회

```
{service_name="preorder", deployment_environment="prod"} | event_id="<uuid>"
{service_namespace="nova"} | aggregate_type="PREORDER" | aggregate_id="<uuid>"
```

인덱스 라벨은 `service_name` · `service_namespace` · `deployment_environment` 뿐이다(`loki.yaml` 의 `ignore_defaults` 와 지정 목록).
`event_id` · `traceId` · `service_instance_id` 같은 값은 structured metadata 라 `| key="값"` 으로 거른다. 라벨로 올리면 값마다 스트림이 생긴다.

**admin 비밀번호 교체.** `GF_SECURITY_ADMIN_PASSWORD__FILE` 는 Grafana 를 처음 띄울 때만 적용된다.
이미 있는 admin 은 Grafana 컨테이너에서 `grafana cli admin reset-admin-password --password-from-stdin` 으로 바꾼다.

## 보안 판단

- **OTLP 에 TLS · 토큰을 붙이지 않는다.** VPC 안 통신이고, 보낼 수 있는 쪽은 obs 보안 그룹이 정한다. 보내는 쪽이 로그를 읽을 경로는 없다. 대신 아래를 받아들인다.
  - 보낼 수 있는 곳이면 로그를 지어내 넣을 수 있다. **로그의 진위는 보장하지 않는다.**
  - 많이 보내면 Collector 메모리 한도에 걸려 다른 서비스의 로그까지 버려진다.
- Loki API 에는 인증이 없다(`auth_enabled: false`). 태스크 안에서만 닿는다. 삭제 요청 API 는 꺼 두었다(`deletion_mode: disabled`). 보존 기간에 따른 삭제는 compactor 가 한다.
- Grafana 는 익명 접근 · 가입 · 플러그인 관리가 꺼져 있다.
- Collector 는 리소스 속성을 **허용 목록**으로만 남긴다. AWS 리소스 감지를 켜면 붙는 `aws.ecs.*` · `cloud.account.id` 는 계정 ID 를 담는다. 이것도 버린다.
- **손실을 허용하는 경로다.** Collector 에 디스크 큐가 없고, 메모리가 차면 받기를 거부하고, obs 가 내려가 있는 동안의 로그는 오지 않는다. 정본(outbox 등)의 근거로 쓰지 않는다.

**대시보드.** `grafana/dashboards/<폴더>/` 가 같은 이름의 Grafana 폴더다(위 "파일" 표). 개요(`nova-overview`, 첫 화면) → 서비스 상세(`nova-service`, `$service`) → 트러블슈팅(`nova-troubleshooting`) 순으로 내려가고,
데이터(MySQL · Valkey · SQS)와 실행 환경(ECS · ALB · CloudFront)은 `20 Data` · `30 Platform` 에서 본다. `nova` 폴더에는 경보 규칙만 있다.
HikariCP 대기 · 사용 시간은 에이전트가 보내는 이름(`db_client_connections_*_milliseconds`, 초로 바꿔 그린다)과 새 semconv 이름(`db_client_connection_*_seconds`)을 함께 조회한다.

**지표.** Mimir 데이터소스에서 PromQL 로 본다. 이름은 Prometheus 관례(단위 · 종류 접미사)다: `http.server.request.duration` → `http_server_request_duration_seconds_bucket`.
`job` 라벨은 `<service.namespace>/<service.name>`(예 `nova/preorder`), `deployment_environment` · `service_namespace` 도 라벨이다. 다른 리소스 속성은 `target_info` 에만 있다.
`target_info` 에는 `service_namespace` 라벨이 없다. 앱만 고를 때는 `target_info{job=~"nova/.+"}` 로 거른다.
Collector 자기 지표는 `job="otelcol-contrib"` 다.

**트레이스.** Grafana Explore 에서 Tempo 를 고르거나, 로그 줄을 펼쳐 trace_id 의 "Tempo" 링크로 간다.
스팬에서는 "Logs for this span" 이 같은 서비스의 같은 trace_id 로그를 연다.

## 저장 전 마스킹

Collector 가 Loki 에 넘기기 전에 개인정보 원문을 고정 표시로 바꾼다(`collector.yaml` 의 `transform/mask`).
조회 경로에서 가리면 Grafana Explore · Loki API 로 직접 볼 때 가려지지 않으므로, 저장 전에 지운다. **되돌릴 수 없다.**

| 대상 (이 순서로) | 바뀐 모습 |
|---|---|
| MySQL 중복 키 값 `Duplicate entry '<값>' for key` — 한 줄 안에서만 | `Duplicate entry '<masked>' for key` |
| 이메일 `local@domain.tld` · `local%40domain.tld` | `<masked:email>` |
| 국제 형식 휴대전화 `+82` · `%2B82` · `0082`, `(0)` 허용 | `<masked:phone>` |
| 휴대전화 `010` · `011` · `016`~`019`, 괄호 · 구분자(`-` `.` 공백) 허용 | `<masked:phone>` |

- **어디에**: 로그 본문(맵 · 목록 본문은 JSON 문자열로 바꾼 뒤 건다), 로그 레코드 속성의 모든 문자열 값(`exception.message` · `exception.stacktrace` 포함).
- **트레이스**(`transform/mask-spans`): 스팬 속성 · 스팬 이벤트 속성(예외) · 상태 메시지에 같은 패턴을 같은 순서로 건다. 더해서 URL 쿼리 문자열은 **값을 모두** 지운다(`url.query` · `url.full` · `http.url` · `http.target`, 이름은 남긴다). 쿼리의 토큰은 패턴에 걸리지 않기 때문이다. SQL 리터럴은 에이전트가 `?` 로 바꿔 보낸다(기본값).
- **경계**: 번호 앞뒤가 16진수 문자가 아니어야 건다. UUID · trace ID · 16진수 ID 안의 숫자는 걸리지 않는다.
- **`error_mode: ignore`**: 문 하나가 실패하면 그 문만 건너뛴다. `propagate` 는 배치 전체를 버린다(503).
- **걸리지 않는 것**: 실명 · 주소 · 유선 전화 · 외국 번호, 16진수 글자 바로 옆의 번호(`phone010…`), `for key` 가 같은 줄에 없는 중복 키 값, 맵 · 목록 **속성** 안의 값, 바이트 본문, 스코프 속성.
- **오탐**: `0.0101234567` → `0.<masked:phone>`, 0 을 채운 `010…` 10~11자리 숫자 ID.
- CloudWatch(`awslogs`) 사본은 이 Collector 를 거치지 않으므로 **원문 그대로 남는다.**
- 안전망이다. 1차 방어는 앱이 애초에 남기지 않는 것이다.

