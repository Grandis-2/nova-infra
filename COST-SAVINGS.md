# 비용 절감 기록

[README](README.md)는 비용을 따지지 않고 설계한 목표 구조를 설명합니다. 실제 운영 환경에서는 비용을 줄이려고 아래 항목을 더 저렴한 방식으로 운영합니다.

대부분은 변수 하나만 바꾸면 목표 구조로 되돌릴 수 있습니다. 트래픽이 늘거나 예산이 확보되면 절감 효과가 큰 항목(표의 위쪽)부터 되돌립니다.

## 한눈에 보기

| 항목 | 목표 구조 | 지금 운영 | 월 절감 (추정) | 되돌리는 방법 |
| --- | --- | --- | --- | --- |
| VPC 인터페이스 엔드포인트 | ECR · Logs · Secrets Manager · SSM 엔드포인트 | 꺼 둠. AWS API 호출이 NAT를 거침 | 약 130달러 | vpc `enable_interface_endpoints = true` |
| Fargate 용량 | 서비스마다 온디맨드 1개, 늘어나는 태스크는 Spot | 전부 Spot (mock 만 온디맨드) | 약 160달러 | ecs `spot_on_demand_base = 1` |
| DB | AWS RDS for MySQL Multi-AZ, db 서브넷 | NCP Cloud DB for MySQL 단일, NAT 고정 IP 로 접속 | 약 110달러 | RDS 스택을 만들고 이관 |
| Container Insights | 켬 (태스크 단위 지표) | 끔. 무료 `AWS/ECS` 지표와 ECS 이벤트 경보로 대신 | 약 75달러 | ecs `container_insights = "enhanced"` |
| NAT | NAT Gateway, AZ마다 하나 | NAT 인스턴스(fck-nat t4g.micro) AZ마다 하나 | 약 70달러 + 처리 요금 | vpc `nat_mode = "gateway"` |
| obs 호스트 크기 | t4g.large (2 vCPU · 8 GiB) | t4g.medium (2 vCPU · 4 GiB), 컨테이너 메모리 한도를 실측으로 다시 나눔. 부하 시험 기간(2026-10-19부터 2~3일)에는 large 로 잠시 되돌린다 | 약 30달러 | ecs `obs_instance_type`, lgtm `obs_memory` |
| mock 최소 대수 | 2대 | 1대 | 약 30달러 | `application/mock/service.yml` 의 `scaling.min` |
| waitingroom · preorder 크기 | 2 vCPU · 4 GiB | 1 vCPU · 2 GiB, 몰리면 오토스케일링 | 약 20달러 | 각 `service.yml` 의 `cpu` · `memory` |
| Atlantis 진입로 | 전용 ALB | 메인 ALB를 같이 쓰고 CloudFront 뒤에 둠 | 약 20달러 | atlantis-deploy 저장소 |
| Valkey | 복제본 + 자동 장애조치 (Multi-AZ) | 노드 1개 | 약 20달러 | elasticache `multi_az = true` |
| 엣지 로그 Lambda → 게이트웨이 | 내부 NLB | 게이트웨이 태스크 IP를 가리키는 DNS 레코드 | 약 16달러 | lgtm `gateway.tf` |
| VPC Flow Logs | 켬 | 끔 | 트래픽에 비례 | vpc `enable_flow_logs = true` |

모두 합하면 한 달에 약 680달러를 절감합니다. 현재 운영비는 한 달에 약 230달러입니다.

금액은 서울 리전 정가로 계산한 추정치이며, 트래픽, 태스크 수, 크레딧에 따라 달라집니다.

## 항목별로 감수하는 것

**VPC 인터페이스 엔드포인트.** ECR 이미지 pull, 비밀 조회, 로그 전송이 NAT를 거쳐 인터넷 경로로 나갑니다. 그래서 NAT가 멈추면 새 태스크가 뜨지 못합니다. AWS API 호출만 따로 보안 그룹으로 통제할 수도 없습니다.

**Fargate Spot.** 서비스마다 최소 대수가 1대라서, Spot이 회수되면 새 태스크가 뜰 때까지 그 서비스가 멈춥니다. mock은 판정용 부하를 받는 서비스라 대수가 바뀌면 안 되므로 온디맨드로 운영합니다.

**NCP DB.** AWS와 NCP 사이에는 사설망이 없어서 DB 연결이 인터넷을 거칩니다. 그 결과 다음을 감수합니다.
- NCP 방화벽(ACG)은 NAT 고정 IP 두 개에서 오는 연결만 허용하고, JDBC 연결에는 TLS를 강제합니다.
- NAT가 DB 경로의 단일 장애점이 됩니다.
- Multi-AZ 장애조치가 없습니다.
- DB 계정에 PROCESS 권한을 줄 수 없어 계정별 연결, 쿼리 상태, 교착 상태 지표를 수집할 수 없습니다. DB 서버의 CPU · 메모리 · 디스크도 NCP Cloud Insight 에만 있어 Grafana 에서 보지 못합니다.

RDS로 이관할 때 필요한 출력값과 설정은 관측 스택 README의 "DB 지표" 절에 정리되어 있습니다.

**Container Insights.** "목표 대비 모자란 태스크 수"와 태스크 단위 CPU · 메모리를 볼 수 없습니다. 대신 서비스별 "태스크 0개" 경보와 ECS 이벤트 경보(배포 실패, 배치 실패, 태스크 비정상 종료)로 장애의 원인이 되는 이벤트를 알립니다.

**NAT 인스턴스.** 처리량이 인스턴스 크기(t4g.micro)에 제한되고, 인스턴스가 교체되는 동안에는 그 AZ의 외부 통신이 끊깁니다. 대신 GB당 데이터 처리 요금이 붙지 않습니다.

**obs 호스트 축소.** 메모리 여유가 줄어서, Loki 검색이나 긴 기간 조회가 순간적으로 몰리면 해당 컨테이너가 OOM으로 재시작될 수 있습니다. 그래서 컨테이너별 메모리 한도를 최근 7일 최대 사용량의 1.4~2.5배로 잡고 대시보드로 지켜봅니다.

**서비스 크기 축소와 mock 1대.** 판매 오픈처럼 요청이 몰리는 상황은 오토스케일링으로 대응합니다. 새 태스크가 뜨는 1~2분 동안은 기존 태스크가 부하를 감당해야 합니다.

**Atlantis 진입로 공유.** 배포 도구로 들어가는 경로가 앱 ALB와 CloudFront에 의존합니다. 그래서 ALB나 엣지 설정이 잘못되면, 그 설정을 고쳐야 할 Atlantis에도 접속하기 어려워집니다.

**Valkey 단일 노드.** 노드 장애나 유지 보수가 생기면 캐시와 대기열 상태를 잃고, 노드가 복구될 때까지 캐시를 쓸 수 없습니다.

**엣지 로그 경로.** 게이트웨이가 롤링 배포되는 몇 초 동안은 Lambda가 이미 내려간 태스크로 데이터를 보낼 수 있습니다. 이렇게 실패한 이벤트는 재시도한 뒤 실패 큐에 남습니다.

**Flow Logs.** 거부된 연결이나 이상 트래픽을 나중에 추적할 기록이 남지 않습니다.
