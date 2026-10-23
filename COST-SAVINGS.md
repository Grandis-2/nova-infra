# 비용 절감 기록

[README](README.md)는 비용을 따지지 않은 목표 구조를 설명합니다. 실제 운영 환경은 비용을 줄이려고 아래 항목을 더 싼 방식으로 돌립니다.

대부분은 변수 하나만 바꾸면 목표 구조로 돌아갑니다. 트래픽이 늘거나 예산이 생기면 절감액이 큰 항목(표의 위쪽)부터 되돌립니다.

## 한눈에 보기

| 항목 | 목표 구조 | 지금 운영 | 월 절감 (추정) | 되돌리는 방법 |
| --- | --- | --- | --- | --- |
| VPC 인터페이스 엔드포인트 | ECR, Logs, Secrets Manager, SSM 엔드포인트 | 꺼 둠. AWS API 호출이 NAT를 거침 | 약 130달러 | vpc `enable_interface_endpoints = true` |
| Fargate 용량 | 서비스마다 온디맨드 1개, 늘어나는 태스크는 Spot | 전부 Spot (mock만 온디맨드) | 약 160달러 | ecs `spot_on_demand_base = 1` |
| DB | RDS for MySQL Multi-AZ | RDS for MySQL 단일 AZ(db.t4g.large) | 약 120달러 | rds `main.tf`의 `multi_az = true` |
| Container Insights | 켬 (태스크 단위 지표) | 끔. 무료 `AWS/ECS` 지표와 ECS 이벤트 경보로 대신 | 약 75달러 | ecs `container_insights = "enhanced"` |
| NAT | NAT Gateway, AZ마다 하나 | NAT 인스턴스(fck-nat t4g.micro) AZ마다 하나 | 약 70달러 + 처리 요금 | vpc `nat_mode = "gateway"` |
| obs 호스트 크기 | t4g.large (2 vCPU, 8 GiB) | t4g.medium (2 vCPU, 4 GiB). 컨테이너 메모리 한도는 실측으로 다시 나눔. 부하 시험 기간에만 t4g.large로 올리고, 끝나면 medium으로 되돌린다 | 약 30달러 | ecs `obs_instance_type`, lgtm `obs_memory` |
| mock 최소 대수 | 2대 | 1대 | 약 30달러 | `application/mock/service.yml`의 `scaling.min` |
| preorder 크기 | 2 vCPU, 4 GiB | 1 vCPU, 2 GiB. 몰리면 오토스케일링으로 버틴다. waitingroom은 첫 몰림을 한 대가 받아야 해서 목표 크기 그대로 둔다 | 약 10달러 | `application/preorder/service.yml`의 `cpu`, `memory` |
| Atlantis 진입로 | 전용 ALB | 메인 ALB를 같이 쓰고 CloudFront 뒤에 둠 | 약 20달러 | atlantis-deploy 저장소 |
| Valkey | 복제본 + 자동 장애조치 (Multi-AZ) | 노드 1개 | 약 20달러 | elasticache `multi_az = true` |
| 엣지 로그 Lambda → 게이트웨이 | 내부 NLB | 게이트웨이 태스크 IP를 가리키는 DNS 레코드 | 약 16달러 | lgtm `gateway.tf` |
| VPC Flow Logs | 켬 | 끔 | 트래픽에 비례 | vpc `enable_flow_logs = true` |

모두 합하면 한 달에 약 680달러를 절감합니다. 현재 운영비는 한 달에 약 240달러입니다.

금액은 서울 리전 정가로 계산한 추정치이며, 트래픽, 태스크 수, 크레딧에 따라 달라집니다.

## 항목별로 감수하는 것

**VPC 인터페이스 엔드포인트.** ECR 이미지 pull, 비밀 조회, 로그 전송이 NAT를 거쳐 인터넷 경로로 나갑니다. 그래서 NAT가 멈추면 새 태스크가 뜨지 못합니다. AWS API 호출만 따로 보안 그룹으로 통제할 수도 없습니다.

**Fargate Spot.** 대부분의 서비스는 최소 대수가 1대라서, Spot이 회수되면 새 태스크가 뜰 때까지 그 서비스가 멈춥니다. mock은 판정용 부하를 받는 서비스라 대수가 바뀌면 안 되므로 온디맨드로 운영합니다.

**RDS 단일 AZ.** 대기 인스턴스가 없어서 그 AZ에 장애가 나거나 인스턴스가 재부팅되는 동안(엔진 패치, 정적 파라미터 변경) DB가 멈추고, 모든 서비스의 쓰기가 실패합니다. 인스턴스가 망가지면 자동 백업(7일)에서 새 인스턴스로 복원해야 합니다. DB는 VPC 안 db 서브넷에 있고 TLS로만 접속합니다.

**Container Insights.** "목표 대비 모자란 태스크 수"와 태스크 단위 CPU와 메모리를 볼 수 없습니다. 대신 서비스별 "태스크 0개" 경보와 ECS 이벤트 경보(배포 실패, 배치 실패, 태스크 비정상 종료)로 장애의 원인이 된 이벤트를 알립니다.

**NAT 인스턴스.** 처리량이 인스턴스 크기(t4g.micro)에 제한되고, 인스턴스가 교체되는 동안에는 그 AZ의 외부 통신이 끊깁니다. 대신 GB당 데이터 처리 요금이 붙지 않습니다.

**obs 호스트 축소.** 메모리 여유가 줄어서, Loki 검색이나 긴 기간 조회가 순간적으로 몰리면 해당 컨테이너가 OOM으로 재시작될 수 있습니다. 그래서 컨테이너별 메모리 한도를 최근 7일 최대 사용량의 1.4~2.5배로 잡고 대시보드로 지켜봅니다.

**서비스 크기 축소와 mock 1대.** 판매 오픈처럼 요청이 몰리는 상황은 오토스케일링으로 대응합니다. 새 태스크가 뜨는 1~2분 동안은 기존 태스크가 부하를 감당해야 합니다.

**Atlantis 진입로 공유.** 배포 도구로 들어가는 경로가 앱 ALB와 CloudFront에 의존합니다. 그래서 ALB나 엣지 설정이 잘못되면, 그 설정을 고쳐야 할 Atlantis에도 접속하기 어려워집니다.

**Valkey 단일 노드.** 노드 장애나 유지 보수가 생기면 캐시와 대기열 상태를 잃고, 노드가 복구될 때까지 캐시를 쓸 수 없습니다.

**엣지 로그 경로.** 게이트웨이가 롤링 배포되는 몇 초 동안은 Lambda가 이미 내려간 태스크로 데이터를 보낼 수 있습니다. 이렇게 실패한 이벤트는 재시도한 뒤 실패 큐에 남습니다.

**Flow Logs.** 거부된 연결이나 이상 트래픽을 나중에 추적할 기록이 남지 않습니다.
