# application

폴더 하나가 서비스 하나입니다. 폴더를 만들고 PR을 올리면 ECR, IAM, 보안 그룹, DB 계정, ECS 서비스가 함께 만들어집니다.

```
application/<서비스>/
├── service.yml        인프라 정의
├── application.yml    운영 Spring 설정 (비밀, 주소 제외)
└── secrets.sops.yml   외부 비밀 암호화본 (선택)
```

`service.yml`의 각 필드로 다음 리소스가 만들어집니다(괄호 안은 해당 스택).

| 필드 | 만들어지는 것 |
| --- | --- |
| `cpu` · `memory` · `port` · `deployment` · `scaling` | ECS 서비스, 태스크 정의, 오토스케일링 (ecs) |
| `schedule` | ECS 서비스 대신 태스크 정의만 만들고, 정해진 시각에 한 번 띄우는 스케줄 (ecs · scheduler) |
| `routes` · `health` | ALB 대상 그룹과 리스너 규칙, Blue/Green 전환 (ecs) |
| `calls` · `jwt` | 호출하는 서비스로 가는 보안 그룹 규칙과 Service Connect 주소 (securitygroup · ecs) |
| `db` · `db_account` · `extra_databases` | DB 계정과 비밀, DB 보안 그룹 규칙 (database · secretsmanager) |
| `redis` · `queues` · `uploads` · `upload_cleanup` | 캐시 보안 그룹 규칙, 큐 · 버킷 권한이 든 태스크 역할 (securitygroup · iam) |
| `generated_secrets` · `secrets.sops.yml` | Secrets Manager 비밀과 실행 역할의 읽기 권한 (secretsmanager · iam) |
| `profiling` | 프로파일 에이전트 환경 변수와 obs 수신 포트 규칙 (ecs · securitygroup) |
| `scales` | 그 서비스들의 최소 대수를 바꾸는 권한과 대상 설정. 대상의 min 은 처음 만들 때만 Terraform 이 넣는다 (iam · ecs) |

## service.yml

```yaml
# 필수
cpu: 1024                 # 256 · 512 · 1024 · 2048 · 4096
memory: 2048              # MiB, cpu에 맞는 값
port: 8080                # 0 = 웹 서버 없음 (worker, batch-*)

# 선택 (오른쪽이 기본값)
deploy: true              # false면 ECS 서비스를 띄우지 않음
image_tag: latest         # 커밋 해시 앞 6자리 이상 또는 버전 태그(0.0.N-rM)면 그 이미지로 고정 (숫자뿐인 커밋 해시는 따옴표 필수)
management_port: 0
deployment: rolling       # rolling | blue_green | singleton
spot: true
stop_timeout: 30          # SIGTERM 뒤 강제 종료까지(초, 2~120). 비우면 ECS 기본값(30)
schedule: null            # "cron(0 5 * * ? *)" 처럼 쓰면(Asia/Seoul) 서비스 없이 그 시각에 태스크를 한 번 띄움. 이미지는 일을 마치면 종료해야 함
                          # port: 0 이어야 하고 deployment · scaling · routes 는 쓰지 않음. 회수돼도 되는 작업이라 Spot 으로 띄움

scaling:
  desired: 1
  min: 1
  max: 1                  # max ≤ min이면 오토스케일링 없음. DB를 쓰면 max × 풀 × 2(배포 중)의 합이 RDS 연결 한도를 넘지 않아야 plan 통과
  cpu_target: 60
  requests_per_task: 0    # 1대가 1분에 받는 요청이 넘으면 바로 늘림 (routes 필요). 0이면 CPU 70% · 적체량으로만 바로 늘림
  backlog: { queue: preorder-register, per_task: 50 }   # 큐 적체로 확장 (선택). 여럿이면 queues: [a, b] (메시지 수를 더함)

health:                   # routes가 있으면 필수. routes 없이 쓰면 컨테이너 헬스체크가 됨
  port: 9080
  path: /actuator/health/readiness
  matcher: "200"

routes:                   # ALB 경로. 우선순위가 낮을수록 먼저 매칭
  - priority: 90
    paths: ["/api/v1/*"]
    methods: []           # 비우면 전체. paths + methods는 4개 이하

jwt: none                 # sign | verify | none (verify면 member 접근 자동 허용)
calls:                    # Spring 속성: 호출할 서비스
  spring.http.serviceclient.order.base-url: order
db: null                  # DB 이름
db_account: <서비스>       # DB 계정 비밀 nova-prod/db/app/<이름>. 다른 서비스의 계정을 같이 쓸 때만 적음
extra_databases: {}       # 같은 계정으로 붙는 추가 DB: 속성 접두사
redis: null               # 캐시 클러스터 키 (main)
queues: { send: [], consume: [], dlq: [], dlq_send: [] }   # dlq: DLQ 들여다보기 · 옮기기, dlq_send: 확정 거절을 그 큐의 DLQ 에 바로 넣기(본 큐 이름)
uploads: false            # true면 업로드 버킷에 사진 올리기 권한
upload_cleanup: false     # true면 업로드 버킷의 사진 지우기 권한 (정리 배치)
generated_secrets: {}     # 아래 '비밀' 참고
environment: {}
profiling: false          # true면 프로파일(Pyroscope)을 보냄. 이미지에 /otel/pyroscope-otel.jar 가 있어야 함
scales: []                # 이 앱이 최소 대수를 바꾸는 서비스(대상은 scaling.max > min). 대상의 min 은 그 뒤 Terraform 이 되돌리지 않음
```

모르는 필드가 있거나 필수 필드가 빠지면 plan이 실패합니다.

## application.yml

be의 `application.yml.example`을 복사해 운영 값으로 고칩니다. 공통 파일이 없으니 서비스마다 필요한 값을 모두 적습니다.

다음 값은 인프라가 채우므로 적지 않습니다.

- `spring.application.name`, `server.port`, `management.server.port`
- `spring.datasource.url`, `spring.data.redis.*`
- `jwt.jwk-set-uri`, `calls`에 적은 속성, SQS 리전
- `uploads: true` 또는 `upload_cleanup: true`이면 `nova.upload.bucket`, `nova.upload.cdn-base-url`, `nova.upload.region`
- `scales`가 있으면 `nova.scaling.cluster`, `nova.scaling.region`, `nova.scaling.<대상>.service` · `baseline`(min) · `max`

비밀 값이나 `localhost`를 적으면 plan이 실패합니다. 회차 오픈 때 preorder 대수(`nova.scaling.preorder.surge`, 기본 3)가 ⌈waitingroom `waitingroom.admission.max-global-credit` ÷ preorder `nova.capacity.heartbeat.accept-per-second`⌉ 보다 작거나 preorder `scaling.max` 보다 커도 plan이 실패합니다. 비밀은 `${환경변수}` 자리표시로 씁니다.

## 비밀

### 생성 비밀

JWT 키, 관리자 비밀번호처럼 만들 수 있는 값은 `generated_secrets`에 `환경 변수 이름: 방식`으로 적습니다. Terraform이 만들어 Secrets Manager에 넣습니다.

```yaml
generated_secrets:
  JWT_PRIVATEKEY: rsa-2048
  ADMIN_PASSWORDHASH: admin-bcrypt
  WAITING_TOKEN_SECRET: shared/waiting-token
```

| 방식 | 만드는 값 | 시크릿 이름 |
| --- | --- | --- |
| `rsa-2048` | RSA 2048비트 개인키, PKCS#8 PEM | `nova-prod/app/<서비스>/<키>` |
| `random-48` | 무작위 48바이트, base64 (64자) | `nova-prod/app/<서비스>/<키>` |
| `admin-bcrypt` | 영문·숫자 24자 비밀번호의 bcrypt 해시 (cost 12) | `nova-prod/app/<서비스>/<키>` (해시)<br>`nova-prod/ops/<서비스>/admin-password` (원문, 사람만 읽음) |
| `shared/<이름>` | 무작위 48바이트, base64. 같은 이름을 적은 서비스가 같은 값을 씀 | `nova-prod/shared/<이름>` |

- 키는 환경 변수 이름이라 대문자, 숫자, `_`만 씁니다.
- `shared/` 뒤 이름은 소문자, 숫자, `-`만 씁니다.
- 값은 처음 한 번만 만들어지고, 상태 파일에는 남지 않습니다.
- 값을 새로 만들려면(키 교체) secretsmanager 스택 `terraform.tfvars`의 `secret_versions`에서 번호를 올립니다.
  예: `secret_versions = { "member/JWT_PRIVATEKEY" = 2, "shared/waiting-token" = 2 }`

생성 방식을 추가하려면 `terraform/aws/secretsmanager/grandis-nova/ap-northeast-2/generated.tf`와 `terraform/variables/locals_services.tf`의 검사 목록을 고칩니다.

### 외부 비밀

카카오, 토스 키처럼 외부에서 받은 값은 `secret.yml`에 적고 암호화해서 `secrets.sops.yml`만 커밋합니다.

```bash
scripts/app-secrets.sh encrypt member   # secret.yml → secrets.sops.yml
scripts/app-secrets.sh decrypt member   # 다시 풀기
```

키 이름이 곧 환경 변수 이름입니다 (`KAKAO_CLIENTSECRET` → `kakao.client-secret`). 값을 바꾸면 서비스를 다시 배포해야 반영됩니다.

## 새 서비스 추가

1. 폴더를 만들고 `service.yml`, `application.yml`을 작성합니다.
2. 이미지가 아직 없으면 `deploy: false`로 PR을 올립니다.
3. be가 이미지를 푸시하면 `deploy: true`로 바꿉니다.
