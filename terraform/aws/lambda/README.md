# Lambda

S3에 파일이 생기는 것처럼 가끔 일어나는 일을 처리하는 함수를 모아 둔 스택이다.

| 함수 | 언제 도는가 | 하는 일 |
|---|---|---|
| `nova-prod-edge-logs` | 로그 버킷의 `alb/`, `cloudfront/`에 파일이 생길 때 | ALB와 CloudFront 접근 로그를 OTel 게이트웨이로 보내 Loki에 쌓는다. 부하 시험 요청 줄(User-Agent `nova-loadtest/`)은 버린다 |

## 구조

```
functions/<함수>/              코드와 단위 시험 (저장소 루트)
terraform/aws/lambda/
├── _modules/function/         함수 공통 틀
└── nova_apnortheast2/
    ├── <함수>.tf              함수별 권한, 환경 변수, 네트워크
    └── s3_notifications.tf    S3 이벤트 연결
```

- 코드는 `functions/` 에 두고, Terraform 은 그 폴더를 zip 으로 묶어 올린다. 코드만 바꿔도 Atlantis 가 이 스택을 plan 한다.
- 실행 역할, 로그 보존 기간, 재시도, 실패 큐, 경보는 공통 모듈이 만든다. 함수마다 다시 쓰지 않는다.
- S3 알림 설정은 버킷마다 하나뿐이라 함수별로 만들면 서로 덮어쓴다. 그래서 `s3_notifications.tf` 한 곳에 모은다.
- zip 을 만드는 archive provider 는 공통 모듈에서만 선언한다. 공용 `version.tf` 에 넣으면 모든 스택이 다시 plan 된다.

## 함수 추가

1. `functions/<함수>/handler.py` 와 `tests/` 를 만든다. 외부 패키지 없이 표준 라이브러리와 boto3 만 쓴다.
2. `nova_apnortheast2/<함수>.tf` 에서 `../_modules/function` 을 부른다. `description` 은 ASCII 로 쓴다.
3. VPC 안의 대상을 부르면 `subnet_ids` 와 SG 를 넘긴다. SG 는 securitygroup 스택에 만든다.
4. S3 트리거라면 `s3_notifications.tf` 의 해당 버킷에 블록을 더한다.

## 실패한 이벤트 다시 보내기

두 번 다시 시도해도 실패한 이벤트는 `<함수>-failed` 큐(14일 보관)에 남고, Slack 으로 경보가 온다. 원인을 고친 뒤 쓰기 권한이 있는 역할로 다시 보낸다.

```bash
fn=nova-prod-edge-logs
q=$(aws sqs get-queue-url --queue-name "$fn-failed" --query QueueUrl --output text)
while m=$(aws sqs receive-message --queue-url "$q" --query 'Messages[0]' --output json) && [ "$m" != null ]; do
  # 메시지의 requestPayload 가 원래 이벤트다. 호출이 받아들여졌을 때(202)만 큐에서 지운다
  code=$(aws lambda invoke --function-name "$fn" --invocation-type Event --cli-binary-format raw-in-base64-out \
    --payload "$(jq -r .Body <<<"$m" | jq -c .requestPayload)" --query StatusCode --output text /dev/null) || break
  [ "$code" = 202 ] || { echo "invoke returned $code, stopping"; break; }
  aws sqs delete-message --queue-url "$q" --receipt-handle "$(jq -r .ReceiptHandle <<<"$m")"
done
```

- 파일을 보내다 중간에 실패했다면 앞부분이 이미 들어가 있어서, 다시 보내면 Loki 에 같은 줄이 두 번 남을 수 있다.
- Loki 는 같은 스트림의 가장 새 줄보다 1시간 넘게 오래된 줄을 받지 않는다. 한 시간이 지난 엣지 로그는 다시 보내도 버려지므로 로그 버킷에서 직접 본다.

## 제약

계정의 Lambda 동시 실행 한도가 10 이라 함수별로 동시 실행을 예약할 수 없다. 한도를 올리면 `reserved_concurrency` 로 함수마다 상한을 둔다.
