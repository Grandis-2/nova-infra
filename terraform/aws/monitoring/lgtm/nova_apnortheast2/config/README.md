# lgtm — obs 태스크의 설정과 시험

nova 관측 스택(OTel Collector · Loki · Tempo · Grafana)의 설정 파일과 로컬 시험이다. 로그 부분은 `Grandis-2/nova-observability` 에서 옮겨 왔다.
로그와 트레이스를 받는다. 지표는 NV-431 에서 더한다.

이 폴더는 Terraform 이 읽지 않는다. 설정을 S3 에 올리고 ECS 작업 정의 · 서비스로 띄우는 것은 NV-434 에서 이 스택에 더한다.

```
앱 태스크 ──OTLP──▶ obs 태스크: otel-collector :4317/:4318 ─┬─ 로그 ──────────────▶ loki  :3100 ──▶ S3 (loki 버킷)
                                                          └─ 트레이스(샘플링) ──▶ tempo :3200 ──▶ S3 (tempo 버킷)
                                     grafana :3000 ── loki · tempo 조회   (ECS Exec 포트 포워딩으로만 접속)
```

obs 태스크의 컨테이너는 localhost 를 같이 쓴다(awsvpc). 포트가 겹치면 컨테이너가 죽는다.

| 컨테이너 | 포트 |
|---|---|
| otel-collector | 4317 (OTLP gRPC) · 4318 (OTLP HTTP) · 8888 (자체 지표, localhost) · 13133 (헬스체크) |
| loki | 3100 (HTTP) · 9096 (gRPC) |
| tempo | 3200 (HTTP) · 9097 (gRPC) · 14317 (OTLP gRPC 수신, localhost — Collector 만 보낸다) |
| grafana | 3000 |

Tempo 는 memberlist(7946)를 쓰지 않는다(링은 메모리).

## 파일

| 경로 | 내용 |
|---|---|
| `collector.yaml` | Collector. 로그: `memory_limiter` → 리소스 허용 목록 → 저장 전 마스킹 → `batch` → Loki. 트레이스: `memory_limiter` → 리소스 허용 목록 → tail sampling → 스팬 마스킹 → `batch` → Tempo |
| `loki.yaml` | Loki 단일 바이너리. S3 저장, 보존 기간, 인덱스 라벨 지정, WAL, 삭제 요청 API 끔 |
| `tempo.yaml` | Tempo 단일 바이너리. S3 저장, 보존 기간(compactor), WAL, 정상 종료 때 블록 업로드 |
| `grafana/provisioning/datasources/` | Grafana 데이터소스: Loki(trace_id → Tempo 링크), Tempo(트레이스 → 로그) |
| `test/` | 로컬 시험. `compose.yaml` 은 시험 전용이고 운영에서는 쓰지 않는다 |

## 실행 환경이 넘길 값

설정 파일에는 실행 환경마다 다른 값이 없다. 아래를 컨테이너 환경 변수로 넘긴다.

| 컨테이너 | 변수 | 값 |
|---|---|---|
| otel-collector | `LOKI_OTLP_ENDPOINT` | `http://localhost:3100/otlp` |
| otel-collector | `TEMPO_OTLP_ENDPOINT` | `localhost:14317` (gRPC, TLS 없음) |
| loki | `LOKI_S3_BUCKET` · `LOKI_S3_REGION` | s3 스택 출력 `loki_bucket` 의 버킷, `ap-northeast-2` |
| loki | `LOKI_RETENTION_PERIOD` | `2160h` (90일). 조회 가능 범위(`max_query_lookback`)도 같은 값이다 |
| loki | `LOKI_S3_ENDPOINT` · `LOKI_S3_FORCE_PATH_STYLE` · `LOKI_S3_INSECURE` | 운영에서는 넘기지 않는다(시험의 Floci 용) |
| loki | `LOKI_COMPACTION_INTERVAL` · `LOKI_RETENTION_DELETE_DELAY` | 운영에서는 넘기지 않는다(기본 10m · 2h) |
| tempo | `TEMPO_S3_BUCKET` · `TEMPO_S3_REGION` | s3 스택 출력 `tempo_bucket` 의 버킷, `ap-northeast-2` |
| tempo | `TEMPO_S3_ENDPOINT` | **필수.** `s3.ap-northeast-2.amazonaws.com` (Loki 와 달리 비워 둘 수 없다) |
| tempo | `TEMPO_RETENTION` | `336h` (14일) |
| tempo | `TEMPO_S3_FORCE_PATH_STYLE` · `TEMPO_S3_INSECURE` | 운영에서는 넘기지 않는다(시험의 Floci 용) |
| grafana | `LOKI_URL` · `TEMPO_URL` | `http://localhost:3100` · `http://localhost:3200` |
| grafana | `GF_SECURITY_ADMIN_PASSWORD` | 비밀 주입: `nova-prod/ops/grafana/admin-password` (secretsmanager 스택) |
| grafana | `GF_PATHS_PROVISIONING` | `/config/grafana/provisioning` |

설정 파일은 컨테이너의 `/config/` 아래에 놓인다: `/config/collector.yaml` · `/config/loki.yaml` · `/config/tempo.yaml` · `/config/grafana/**`.
Collector 는 `--config=/config/collector.yaml`, Loki · Tempo 는 `-config.file=/config/<이름>.yaml -config.expand-env=true` 로 띄운다.

작업 정의(NV-434)가 지킬 것 — 시험 compose(`test/compose.yaml`)와 같게 맞춘다.
- 이미지는 태그와 다이제스트로 고정한다(`test/compose.yaml` 의 값).
- 데이터 경로는 재시작 · 인스턴스 교체에도 남는 디스크여야 한다(WAL): loki `/loki`, tempo `/var/tempo` (UID 10001), grafana `/var/lib/grafana` (UID 472).
- Loki · Tempo 의 정지 시간을 넉넉히 준다(`stopTimeout` 120초). 정상 종료 때 들고 있던 청크 · 블록을 S3 로 올린다.
- Collector 메모리는 1 GiB 이상. tail sampling 이 결정 전 트레이스를 메모리에 든다(`memory_limiter` 768 MiB).
- 버킷 정책은 `nova-prod-obs` 역할만 객체에 접근하게 막아 두었다(s3 스택).
- 모든 컨테이너는 리눅스 권한이 필요 없다(1024 위 포트만 쓴다). 권한을 모두 버리고 권한 상승을 막는다.

## 앱이 줄 값

에이전트는 be 이미지의 `/otel/javaagent.jar` 이다(NV-356). 켤 서비스의 작업 정의에 준다.

```
JDK_JAVA_OPTIONS=-javaagent:/otel/javaagent.jar
OTEL_SERVICE_NAME=<svc>
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.namespace=nova
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=none
OTEL_TRACES_SAMPLER=parentbased_always_on
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel.nova.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED=traceId
OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED=event_id,aggregate_type,aggregate_id,event_type,destination
```

- `JAVA_TOOL_OPTIONS` 는 주지 않는다. 이미지의 힙 옵션이 그 변수에 있어 덮으면 사라진다.
- 포트와 프로토콜은 짝을 맞춘다(4317 은 `grpc`, 4318 은 `http/protobuf`). 어긋나면 앱 로그에 실패 한 줄만 남고 아무것도 오지 않는다.
- logback 속성은 2.32.0 의 새 이름이다. 값은 `true` 가 아니라 이름 목록이다.
- MDC 는 `traceId`(요청 ID)만 받는다. `subject`(회원 ID)는 받지 않는다.
- 샘플링은 Collector 가 한다(`parentbased_always_on` 으로 모두 보낸다). 앱에서 자르면 버려진 쪽의 오류 트레이스를 다시 찾을 수 없다.

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
{service_name="nova-preorder", deployment_environment="prod"} | event_id="<uuid>"
{service_name=~"nova-.+"} | aggregate_type="PREORDER" | aggregate_id="<uuid>"
```

인덱스 라벨은 `service_name` · `service_namespace` · `deployment_environment` 뿐이다(`loki.yaml` 의 `ignore_defaults` 와 지정 목록).
`event_id` · `traceId` · `service_instance_id` 같은 값은 structured metadata 라 `| key="값"` 으로 거른다. 라벨로 올리면 값마다 스트림이 생긴다.

**admin 비밀번호 교체.** `GF_SECURITY_ADMIN_PASSWORD__FILE` 는 Grafana 를 처음 띄울 때만 적용된다.
이미 있는 admin 은 Grafana 컨테이너에서 `grafana cli admin reset-admin-password --password-from-stdin` 으로 바꾼다.

## 보안 판단

- **OTLP 에 TLS · 토큰을 붙이지 않는다.** VPC 안 통신이고, 보낼 수 있는 쪽은 obs 보안 그룹이 정한다. 보내는 쪽이 로그를 읽을 경로는 없다. 대신 아래를 받아들인다.
  - 보낼 수 있는 곳이면 로그를 지어내 넣을 수 있다. **로그의 진위는 보장하지 않는다.**
  - 많이 보내면 Collector 메모리 한도에 걸려 다른 서비스의 로그까지 버려진다.
- Loki API 에는 인증이 없다(`auth_enabled: false`). 태스크 안에서만 닿는다. 삭제 요청 API 는 꺼 두었다(`deletion_mode: disabled`, 시험에서 403). 보존 기간에 따른 삭제는 compactor 가 한다.
- Grafana 는 익명 접근 · 가입 · 플러그인 관리가 꺼져 있다.
- Collector 는 리소스 속성을 **허용 목록**으로만 남긴다. AWS 리소스 감지를 켜면 붙는 `aws.ecs.*` · `cloud.account.id` 는 계정 ID 를 담는다. 이것도 버린다(`test/agent-probe.sh` C 가 확인).
- **손실을 허용하는 경로다.** Collector 에 디스크 큐가 없고, 메모리가 차면 받기를 거부하고, obs 가 내려가 있는 동안의 로그는 오지 않는다. 정본(outbox 등)의 근거로 쓰지 않는다.

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

## 시험

`config/` 에서 돌린다. 로컬 Docker 가 필요하고, S3 는 Floci 로 대신한다(실제 AWS 와 다른 점은 `test/compose.local.yaml` 머리말).

| 무엇 | 명령 |
|---|---|
| 끝까지 한 건: Loki API · Grafana 에서 `event_id` 로 찾기, 라벨 · structured metadata, 허용 목록, 트레이스 거부, 익명 401, 삭제 API 403, SIGKILL 뒤 WAL 복구, 정상 종료 뒤 S3 업로드, 로컬 디스크를 비운 뒤 S3 에서 읽기 | `bash test/smoke.sh` |
| 보존 기간이 지난 청크만 compactor 가 S3 에서 지운다 | `bash test/retention.sh` |
| 저장 전 마스킹: 사례 22개 · 바뀌면 안 되는 값 11개 · 예외 메시지 · 맵 / 목록 본문을 필드마다 기대값과 비교 | `bash test/masking.sh` |
| Java 25 + 에이전트 2.32.0 + logback → 스택. 프로토콜 짝, MDC 는 `traceId` 만, `aws.*` 버림 | `bash test/agent-probe.sh` (JDK 25 필요) |
| 트레이스: 오류 트레이스 저장 · 스팬 마스킹(쿼리 값 · 이메일 · 전화 · 중복 키) · 느린 트레이스 저장 · 헬스체크 · 빈 롱폴링 버림 · 10% 샘플링 · Grafana 조회 · 정상 종료 뒤 S3 에서 읽기 | `bash test/traces.sh` |

시험 compose 는 작업 정의와 같은 포트 · 환경 변수 이름 · `/config` 경로를 쓰고, 모든 컨테이너가 한 네트워크 네임스페이스(`netns`)를 같이 쓴다(awsvpc 와 같다).
`KEEP=1` 이면 끝나도 내리지 않는다. 설정을 고치면 시험을 모두 돌린다. 특히 `collector.yaml` 의 마스킹 · 허용 목록을 고칠 때는 `masking.sh` 와 `agent-probe.sh` 가 회귀를 잡는다.
