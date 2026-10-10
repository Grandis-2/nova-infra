# floci 로 로컬 테스트

실제 AWS 에 올리기 전에, [floci](https://floci.io) 에뮬레이터에 **진짜로 apply** 해 본다.
AWS 요금이 들지 않고 실제 계정에는 아무것도 만들지 않는다.

```bash
./scripts/test-local.sh              # 전체 (처음부터 새로)
./scripts/test-local.sh vpc securitygroup # 지정한 스택만 (이름은 test-local.sh 의 stack_dir 표, 기존 상태 위에 이어서)
```

## 무엇을 확인해 주나

| 확인됨                                              | 확인 안 됨                                    |
| --------------------------------------------------- | --------------------------------------------- |
| 문법 · 타입 · 참조 (`validate` 수준)                | 컨테이너가 실제로 뜨는지 · 헬스체크 통과 여부 |
| 리소스 인자가 AWS API 에서 받아들여지는지           | 네트워크가 실제로 통하는지 (SG · 라우팅 효과) |
| 스택 간 output → remote_state 연결                  | IAM 정책이 실제로 허용/거부하는지             |
| `count` · `for_each` 가 apply 시점 값에 걸리는 실수 | DB(NCP) · Redis 가 실제로 접속되는지          |
| write-only 시크릿이 상태에 남지 않는지              | 비용                                          |

`terraform validate` 는 통과하지만 apply 에서만 터지는 결함을 여기서 잡는다.
예를 들어 계획 단계에 값을 알 수 없는 속성(새로 만드는 리소스의 ID·ARN)을 `count` 에 쓴 실수는
`validate` 로는 드러나지 않는다.

## 필요한 것

| 도구             | 확인                |
| ---------------- | ------------------- |
| Docker           | `docker ps`         |
| Terraform ≥ 1.11 | `terraform version` |
| AWS CLI v2       | `aws --version`     |
| python3, curl    |                     |

floci 컨테이너는 스크립트가 알아서 띄운다. 직접 띄우려면:

```bash
docker run -d --name floci -p 4566:4566 floci/floci:latest
```

## 실제 AWS 에 닿지 않는다는 보장

스크립트는 세 겹으로 막는다.

1. **가짜 자격증명 고정** — `AWS_ACCESS_KEY_ID=test` 로 덮어쓴다. 실제 AWS 에 닿아도 인증에서 거부된다.
2. **`~/.aws` 차단** — `AWS_CONFIG_FILE` · `AWS_SHARED_CREDENTIALS_FILE` 을 `/dev/null` 로 돌리고
   `AWS_PROFILE` · 세션 토큰 변수를 지운다. PC 에 있는 키·SSO 캐시를 읽을 수 없다.
3. **계정 확인** — 시작 전에 `sts get-caller-identity` 를 부른다. 결과가 floci 의 가짜 계정
   `000000000000` 이 아니면 아무것도 하지 않고 멈춘다.

직접 확인하려면 테스트 후 상태 파일의 ARN 을 본다.

```bash
grep -ohE 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' ~/.cache/floci-tf/*/terraform.tfstate \
  | awk -F: '{print $5}' | sort | uniq -c
#  → 000000000000 만 나와야 한다
#    (600734575887 은 AWS 가 공개한 서울 리전 ELB 로그 계정. 버킷 정책에 들어가는 상수다)
```

ALB 주소도 `*.elb.localhost.floci.io` 로 나온다.

### CPU · 메모리를 거의 안 쓰는 이유

floci 는 **API 에뮬레이터**다. `CreateDBInstance` 를 받으면 DB 를 띄우는 게 아니라 "DB 가 있다"는
기록만 남기고 그럴듯한 응답을 돌려준다. ECS 서비스도 컨테이너를 실행하지 않는다.
그래서 리소스 수백 개를 만들어도 부하가 낮다. 정상이다. 위 표의 "확인 안 됨" 이 생기는 이유이기도 하다.

## 스크립트가 하는 일

원본 디렉터리는 건드리지 않는다. 스택마다 복사본을 만들어 그 위에서 돌린다.

```
~/.cache/floci-tf/
├── _mods/               로컬 모듈 복사본 (각 서비스의 _modules, 태그를 뺀 것)
├── vpc/                 terraform/aws/vpc/nova_apnortheast2 복사본 + terraform.tfstate
├── database/            ncp/database 대신 쓰는 가짜 스택 (같은 출력 · 시크릿만 floci 에)
├── securitygroup/
└── ...
```

| 단계                                              | 이유                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 심볼릭 링크를 실제 파일로 풀어 복사               | 원본을 수정하지 않으려고                                                                |
| 복사본의 `.terraform/` 삭제                       | 원본에 받아 둔 프로바이더(스택당 수백 MB)가 딸려 와 한 번에 십수 GB 가 쌓인다           |
| 프로바이더 공유 캐시 (`~/.cache/terraform-plugins`) | 프로바이더를 한 번만 받고 스택마다 링크로 쓴다. 한 번 실행에 작업 폴더는 수십 MB        |
| 복사본의 `global.auto.tfvars` 삭제                | 커밋된 공통 값 대신 테스트용 `TF_VAR_*` 를 쓰려고 (`*.auto.tfvars` 가 환경변수보다 우선) |
| `backend.tf` 삭제 → 로컬 상태                     | S3 상태 버킷 없이 돌리려고                                                              |
| `terraform_remote_state` 를 로컬 경로로 교체      | 앞 스택의 상태 파일을 그대로 읽으려고                                                   |
| provider 에 `s3_use_path_style = true`            | 에뮬레이터가 `<버킷>.localhost` 형식을 못 받는다                                        |
| 태그 인자 제거                                    | 일부 서비스의 태그 API 가 구현돼 있지 않다                                              |
| 엔드포인트를 `localhost.localstack.cloud:4566` 로 | `*.localhost` 는 DNS 로 안 풀린다. 이 도메인은 모든 하위 이름이 `127.0.0.1` 을 가리킨다 |
| CloudFront prefix list · AMI 를 변수로 대체       | AWS 관리형 리소스라 에뮬레이터에 없다                                                   |
| atlantis-deploy 는 옆 디렉터리에서 찾는다         | 별도 저장소다. `../atlantis-deploy` 또는 `ATLANTIS_DIR`. 없으면 건너뛴다                |

`localhost.localstack.cloud` 는 이름만 빌려 쓰는 것이다. 공개 DNS 가 `127.0.0.1` 로 풀어 줄 뿐,
요청은 전부 로컬의 floci 컨테이너로 간다.

인자 없이 실행하면 floci 컨테이너와 상태를 지우고 처음부터 시작한다.
스택을 지정하면 기존 상태 위에 이어서 적용한다.

## 결과 읽기

```
대상 확인: http://localhost.localstack.cloud:4566 (account 000000000000)
== vpc
   ok  27 리소스
== securitygroup
   ok  58 리소스
...
전부 통과. 상태 파일은 /home/<사용자>/.cache/floci-tf 에 있다.
```

실패하면 해당 스택의 마지막 25줄이 출력된다. `Error:` 줄부터 읽는다.

만들어진 리소스를 직접 보려면 같은 설정으로 AWS CLI 를 부른다.

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=ap-northeast-2
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null

aws ecs list-services --cluster nova-prod
aws secretsmanager list-secrets --query 'SecretList[].Name' --output text   # nova-prod/db/app/* 등
aws elbv2 describe-rules --listener-arn "$(aws elbv2 describe-listeners \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --names nova-prod-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'Listeners[0].ListenerArn' --output text)"
```

## 에뮬레이터 한계

| 항목                  | 증상                                                  | 대응                                             |
| --------------------- | ----------------------------------------------------- | ------------------------------------------------ |
| `edge` 스택           | CloudFront 관리형 캐시 정책 조회 실패                 | 기본 목록에서 제외. 실제 AWS 에서 plan 으로 확인 |
| `bastion` 스택        | EC2 인스턴스 타입 정보 없음                           | 기본 목록에서 제외                               |
| 같은 상태 위에 재적용 | ecs 서비스에 가짜 변경 (`launch_type` 을 함께 돌려줌) | 전체 실행은 매번 새로 시작                       |
| 태그                  | 복사본에서 제거하고 돌림                              | 태그 자체는 검증되지 않는다                      |
| NCP                   | 에뮬레이터가 없다                                     | database 는 가짜 스택. 실제 계정에서 plan 으로 확인 |
| NAT 인스턴스(fck-nat) | ENI source/dest check 변경을 지원하지 않는다          | floci 에서만 `nat_mode = "gateway"` 로 돌린다    |
| Atlantis 근무 시간 예약 | `PutScheduledAction` 을 지원하지 않는다 | floci 에서만 `schedule_enabled = false` |
| 실제 sops 파일 | 진짜 KMS 로 암호화돼 에뮬레이터에서 풀 수 없다 | 복사본에서 `secrets.sops.yml` 을 빼고 시험 (비밀 환경변수 없이) |
| 보안 그룹 규칙 한도   | 진짜 CloudFront prefix list(약 55개 항목) 대신 작은 목록을 씀 | 규칙 한도 초과는 실제 AWS 에서만 드러난다        |
| 인스턴스 · 기능 제약  | 예: db.t4g.micro 의 Performance Insights 를 그냥 받아 준다 | 인스턴스 타입별 제약은 검증되지 않는다           |

설정 문제로 보이는 실패가 나오면 위 표에 해당하는지 먼저 본다.

## 새 스택을 추가할 때

1. `scripts/test-local.sh` 의 기본 `stacks=(...)` 목록에 의존 순서대로 넣는다
2. AWS 관리형 리소스를 `data` 로 조회한다면(관리형 정책·공개 AMI·prefix list 등)
   값을 직접 받을 수 있는 변수를 두고, 비어 있을 때만 `data` 를 쓰게 한다.
   운영에서도 값을 고정하고 싶을 때 쓸모가 있다. (예: `securitygroup` 의 `cloudfront_prefix_list_id`)
3. `count` · `for_each` 의 조건에는 **계획 단계에 알 수 있는 값**(변수·불리언)만 쓴다

## 문제 해결

| 증상                             | 원인                                 | 해결                                                              |
| -------------------------------- | ------------------------------------ | ----------------------------------------------------------------- |
| `중단: 에뮬레이터 계정이 아니다` | floci 가 아닌 곳에 붙었다            | 4566 포트를 다른 프로그램이 쓰는지 확인 (`ss -ltnp \| grep 4566`) |
| `failed to instantiate provider` | 작업 디렉터리가 `noexec` 로 마운트됨 | `FLOCI_WORKDIR=~/somewhere ./scripts/test-local.sh`               |
| `floci 컨테이너를 띄우지 못했다` | Docker 미실행 · 이미지 pull 실패     | `docker ps`, 네트워크 확인                                        |
| `No stored state was found`      | 앞 스택을 안 돌리고 뒤 스택만 지정   | 의존 스택부터 함께 지정하거나 인자 없이 전체 실행                 |

## 정리

```bash
docker rm -f floci
rm -rf ~/.cache/floci-tf
```
