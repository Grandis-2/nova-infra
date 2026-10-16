# Lambda

ECS 서비스로 띄우기엔 작은 일, 이벤트가 생길 때만 도는 일을 Lambda 로 둔다. 지금은 엣지 접근 로그를 Loki 로 보내는 함수 하나다(NV-542).

| 함수 | 트리거 | 하는 일 |
|---|---|---|
| `nova-prod-edge-logs` | 로그 버킷 `alb/` · `cloudfront/` 에 파일 생성 | 접근 로그를 줄마다 OTLP 로그로 바꿔 OTel 게이트웨이(`otel-ingest.nova.local:4318`)로 보낸다 |

## 구조

```
functions/<이름>/                  코드(Python)와 단위 시험 — 저장소 루트
terraform/aws/lambda/
├── _modules/function/             모든 함수의 틀
└── nova_apnortheast2/             이 VPC 의 함수들
    ├── <이름>.tf                  함수 하나: 트리거 권한 · API 권한 · 환경 변수 · 네트워크
    └── s3_notifications.tf        버킷별 S3 이벤트 연결
```

- **코드와 Terraform 을 나눴다.** `functions/` 는 Python 만 있어 시험과 린트를 거기서 돌린다. Terraform 은 경로(`source_dir`)만 받아 plan 때 zip 으로 묶는다.
  zip 해시가 바뀌면 함수가 다시 올라간다. Atlantis 는 `functions/**` 가 바뀌어도 이 스택을 plan 한다.
- **틀을 모듈 하나로 둔다.** 실행 역할(자기 로그 그룹에만 쓰기), 로그 보존, 비동기 재시도, 실패 큐, 경보를 함수마다 따로 쓰지 않는다.
- **archive provider 는 모듈 안에서만 선언한다.** 공용 `version.tf` 에 넣으면 모든 스택이 다시 plan 된다.
- **S3 이벤트 연결은 `s3_notifications.tf` 한 곳에 모은다.** S3 알림 설정은 버킷마다 리소스 하나가 전부를 정해서, 함수별로 만들면 서로 덮어쓴다.
- **lgtm 스택과 분리했다.** 함수를 바꿔도 obs · 게이트웨이를 잠그거나 재배포하지 않는다. 대신 게이트웨이 주소를 lgtm 출력에서 읽어 적용 순서가 lgtm 다음(7)이다.

## 함수 더하기

1. `functions/<이름>/handler.py` 와 `tests/` 를 만든다. 표준 라이브러리 · 런타임의 boto3 만 쓴다(외부 패키지가 필요해지면 묶기 단계를 모듈에 더한다).
2. `nova_apnortheast2/<이름>.tf` 에 `module "<이름>" { source = "../_modules/function" ... }` 를 쓴다. `description` 은 ASCII 로.
3. VPC 안 대상(Service Connect 밖 이름, DB 등)을 부르면 `subnet_ids` 와 securitygroup 스택의 SG 를 넘긴다.
4. 트리거를 연결한다. S3 면 `s3_notifications.tf` 의 버킷 리소스에 블록을 더한다.

## 실패 처리

- 비동기 호출(S3 이벤트)은 실패하면 Lambda 가 2번 다시 시도한다.
- 그래도 실패하면 이벤트가 실패 큐(`<함수>-failed`, SQS, 14일 보관)에 원래 요청과 오류를 담아 남고, `<함수>-failed` 경보가 Slack 으로 온다. 재시도로 결국 성공한 일시 오류는 울리지 않는다.
- 원인을 고친 뒤 큐의 이벤트를 다시 보낸다. 쓰기 권한이 있는 역할로 실행한다.

```bash
fn=nova-prod-edge-logs
q=$(aws sqs get-queue-url --queue-name "$fn-failed" --query QueueUrl --output text)
while m=$(aws sqs receive-message --queue-url "$q" --max-number-of-messages 1 --query 'Messages[0]' --output json) && [ "$m" != null ]; do
  # 메시지 본문의 requestPayload 가 원래 이벤트다
  aws lambda invoke --function-name "$fn" --invocation-type Event --cli-binary-format raw-in-base64-out \
    --payload "$(jq -r .Body <<<"$m" | jq -c .requestPayload)" /dev/null
  aws sqs delete-message --queue-url "$q" --receipt-handle "$(jq -r .ReceiptHandle <<<"$m")"
done
```

엣지 로그 함수는 파일 중간에서 실패하면 앞 묶음이 한 번 더 들어갈 수 있다(같은 줄이 Loki 에 두 번). 집계 패널이 잠깐 부풀 수 있다.

## 제약

- **계정 동시 실행 한도가 10 이다.** 이 한도에서는 함수별 예약 동시 실행을 둘 수 없다(예약하지 않은 몫이 최소 10 이어야 한다). 계정 한도가 상한이 된다. 한도를 올리면 받는 쪽을 지키도록 `reserved_concurrency` 를 둔다.
- VPC 안 함수는 ENI 를 쓴다. 처음 뜰 때(콜드 스타트) 몇 초 더 걸린다. S3 는 게이트웨이 엔드포인트로, CloudWatch Logs 는 NAT 로 나간다.
