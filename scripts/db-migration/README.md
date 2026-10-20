# NCP → RDS 이전 런북 스크립트

NCP Cloud DB for MySQL 을 RDS for MySQL 로 옮길 때, Terraform 이 할 수 없는 SQL 단계를 돌리는 스크립트다.
데이터는 binlog 복제로 미리 맞춰 두고, 쓰기 대상 전환은 ProxySQL 이 요청을 잠깐 기다리게 한 채 넘긴다.
접속 정보는 환경변수로 받고(`lib.sh` 머리말), 비밀번호는 화면 · 파일 · 명령 인자에 남기지 않는다. `bash -x` 로 돌리지 않는다.

| 스크립트 | 언제 | 하는 일 |
|---|---|---|
| `00-precheck.sh` | 사전 점검 (G1) | NCP 를 읽기만 해서 복제 소스가 될 수 있는지 판정한다 |
| `10-ncp-users.sh` | 복제 준비 | NCP 에 `repl_rds`(복제) · `proxysql_mon`(감시) · `dump_rds`(덤프) 를 만든다. 덤프보다 먼저 돌린다 |
| `40-replication.sh g2` | RDS 를 만든 직후 (G2) | RDS 가 NCP 에 복제 연결을 맺는지만 보고 지운다. RDS 에 아무것도 적용하지 않는다 |
| `20-rds-accounts.sh` | 복제 준비 | RDS 에 NCP 와 같은 이름 · 비밀번호 · 권한의 계정을 만든다 (RDS `read_only=0` 일 때) |
| `30-dump-load.sh` | 복제 준비 | `dump_rds` 로 덤프 → RDS 적재, 체크섬 검증, 복제 시작점 기록. 쓰기를 300ms 넘게 막으면 덤프를 끊는다 |
| `40-replication.sh start` | 복제 준비 | 덤프 위치부터 복제를 시작한다. 전에 RDS 를 `read_only=1` 로 둔다. `status` · `stop` · `resume` · `reset` 도 있다 |
| `40-replication.sh compare` | 복제하는 동안 | 같은 시점의 NCP · RDS 를 표마다 체크섬으로 비교한다. 쓰기를 막지 않고, 비교하는 동안 NCP 에 쓰기가 있었으면 다시 한다 |
| `45-pause-drill.sh` | ProxySQL 도입 뒤 | 쓰기 대상은 그대로 두고 대기 → 재개만 되풀이해 예산(300ms) 안에 끝나는지 잰다 |
| `50-rehearsal-proxysql.sh` | 리허설 | 운영 ProxySQL 에 리허설 그룹(20) · 리허설 서버 · 시험 계정을 런타임에만 넣고(`setup`) 뺀다(`teardown`). 리허설이 운영 RDS 에 남긴 것을 지운다(`clean-rds`) |
| `60-cutover.sh` | 전환 | NCP → RDS. 전에 RDS 를 `read_only=0` 으로 둔다. 끊겼으면 `60-cutover.sh recover` |
| `70-rollback.sh` | 전환 뒤 ~ NCP 해체 전 | RDS → NCP 를 통째 복사로 되돌리는 비상 경로(복사하는 동안 요청이 실패할 수 있다). 끊겼으면 `recover` |

쓰기를 바꾸는 단계는 한 번에 하나만 돈다(`$WORK_DIR/runbook.lock`). 모르는 인자를 받으면 멈춘다.

운영에서는 운영자 노트북에서 `ops.sh step <단계> [Args]` 로 돌린다. 단계는 bastion 에서 SSM Run Command 로 돌고(Terraform bastion 스택의
SSM 문서), 비밀번호는 bastion 이 Secrets Manager 에서 읽는다. `ops.sh writer` · `running` · `shell` 도 있다.

`RDS_MODE=rds`(기본)는 `mysql.rds_*` 프로시저를 쓰고, `RDS_MODE=native` 는 로컬 시험에서 같은 일을 MySQL 명령으로 한다.

## 전환이 요청을 기다리게 하는 시간

`60-cutover.sh` 는 NCP 에 묶인 뒷단 연결이 0 인 순간을 기다렸다가 NCP 를 `OFFLINE_SOFT` 로 바꾸고, 비우기 · 따라잡기 확인이
`BUDGET_MS`(기본 300)에서 `BUDGET_MARGIN_MS`(기본 50)를 뺀 시간 안에 끝나면 RDS 로 넘긴다. 넘으면 NCP 로 되돌리고 다시 시도한다
(`ATTEMPTS` 번). 시간이 중요한 조회는 연결을 열어 둔 채 다시 쓴다(`lib.sh` 의 세션). 복제는 RDS 로 넘긴 뒤에 멈춘다.

조용한 순간이 `QUIET_WAIT_MS`(기본 10초) 동안 오지 않으면 아무것도 바꾸지 않고 멈추고, 뒷단 연결을 쥔 세션을 보여 준다.
`@@` 변수를 묻는 쿼리가 ProxySQL 연결을 고정했거나(쿼리 규칙 추가) 긴 트랜잭션이 있는 것이다.

## 쓰기 대상 기록과 새로 뜨는 ProxySQL 태스크

ProxySQL 태스크는 시작할 때 쓰기 대상 기록(SSM `writer`)을 읽어 그 서버만 넣는다. `60` · `70` 은 대기를 시작하기 전에 기록을
`switching-rds` · `switching-ncp` 로 두고(방향이 남아 다른 스크립트의 recover 는 멈춘다), 끝나면 실제 쓰기 대상으로 바꾼다. 그사이 새로 뜨는 태스크는 설정을 만들지 못해 트래픽을 받지 않는다
(ECS 가 다시 띄우므로 끝난 뒤 뜬다. 되풀이해 실패하면 ECS 가 띄우는 간격을 늘려 한동안 노드가 1대일 수 있다).
`switching` 을 쓴 직후와 끝날 때 노드 목록을 실제(ECS 의 모든 태스크 + NLB 의 모든 대상)와 대조한다. 태스크가 바뀐 직후에는
NLB 에서 빠지는 옛 대상(30초) 때문에 대조가 어긋나 멈춘다. 잠시 뒤 다시 한다.

## 끊겼을 때 (`recover`)

`60` · `70` 은 어떻게 끝나든(오류 · 시간 초과 · Ctrl-C) 노드 상태를 실제로 읽어 한쪽으로 맞춘다. 받을 서버가 한 노드에서라도
빠져 있지 않으면(`ONLINE` · `SHUNNED` 등) 모두 받을 서버로, 모든 노드에서 빠져 있으면 모두 원래 서버로 맞추고, 쓰기 대상 기록(SSM)과 복제도 그쪽에 맞춘다.
실행하던 곳을 잃으면(SSM 세션 · bastion) 이 정리가 돌지 않아 요청이 ProxySQL 안에서 최대 30초 기다린 뒤 실패한다.
그때는 바로 `60-cutover.sh recover`(되돌리기 중이었으면 `70-rollback.sh recover`)를 돌린다.
Run Command 로 돌렸다면 원래 명령이 아직 bastion 에서 돌 수 있다. recover 는 그때 잠금 때문에 멈추므로, 명령 상태를 확인하고 끝난 뒤 돌린다.
recover 는 NCP · RDS 에 닿지 않아도 노드부터 맞춘다. 노드를 다 읽지 못해 방향을 정하지 못하면 기록을 `switching` 으로 둔 채 실패로
끝난다(다시 돌린다). SSM 을 쓰는 운영에서는 끊긴 실행이 남긴 기록이 뒤늦게 덮지 않았는지 21초 뒤 한 번 더 본다.

## 전환이 끝난 뒤

1. `40-replication.sh reset` 으로 복제 설정을 지운다. RDS 에 저장된 복제 계정 비밀번호도 함께 지워진다
   (앱 계정이 `SELECT ON mysql.*` 로 읽을 수 있어 NCP 권한과 같게 둔 데 따른 노출을 줄인다).
2. Terraform 반영 PR: rds `primary = "rds"`, `replication_filter = false` 등. `primary` 가 쓰기 대상 기록과 다르면 plan 이 멈춘다.
3. 앱 주소를 RDS 로 바꾸고 ProxySQL 을 지운 뒤 NCP 를 내린다(ProxySQL 이 남은 채 NCP 를 내리면 감시 그룹에서 NCP 감시 오류가 계속 쌓인다).

## 리허설

운영 ProxySQL 의 그룹 20 에서, 운영 백업으로 만든 리허설 NCP 와 **아직 비어 있는 운영 RDS** 로 같은 절차를 돌린다(결정 ⑩ B).
ProxySQL 을 만든 뒤, 앱을 붙이기 전, 실제 덤프 전에 한다. SSM 문서는 Args 앞에 `rehearsal <리허설 NCP 도메인>` 을 붙이면 리허설
대상 · 그룹 20 · 파일 기록(bastion `/var/lib/db-migration/rehearsal`)으로 돈다. 리허설 중 RDS 는 `read_only=0` 인 채로 둔다.

순서: `50 setup` → `10` · `20` · `30` · `40 start` → `45` → `60` → `70` → `50 teardown` → `50 clean-rds` → 리허설 NCP 삭제 → 실제 `20` · `30` …

- `50 setup` 뒤 ProxySQL 감시가 리허설 서버를 한 번 볼 때까지(운영 기본 접속 60초) `60` · `70` 이 기다린다.
- `60` · `70` 은 ProxySQL 의 두 서버와 직접 붙는 DB 주소가 다르면 멈추고, 운영이 아닌 그룹에서는 운영 SSM 기록을 쓰지 않는다.
- `50` 은 리허설 NCP 가 운영 그룹에 있거나, 운영 RDS 가 운영 그룹에서 이미 쓰기 대상이면 멈춘다.
- `50 clean-rds` 는 RDS 가 리허설 NCP 가 아닌 곳을 복제 중이거나 `read_only=1` 이면(실제 이전이 시작된 것) 지우지 않는다.
- 리허설 기록 파일은 리허설 `70` 으로 ncp 로 돌아온다. 다시 처음부터 하려면 bastion 에서 그 디렉터리를 지운다.

## 같은 시점 비교 (`40-replication.sh compare`)

NCP 를 멈추지 않고 두 DB 가 같은지 본다. NCP `gtid_executed` 를 읽고(G1) RDS 가 그것까지 적용하기를 기다린 뒤 두 쪽 표를 모두
`CHECKSUM TABLE` 하고, NCP `gtid_executed` 를 다시 읽는다(G2). G1 = G2 면 그동안 쓰기가 없었으니 같은 시점의 비교다. 다르면
2초 뒤 다시 한다(30번까지). 앱의 주기 작업도 쓰므로 사람 요청이 없어도 몇 번은 다시 할 수 있다. 사람 요청 자제를 알려 두면
빨리 끝나고, 재고 대조 시각(KST 04 · 05시)은 피한다. 하루 한 번과 전환 직전에 돌린다. 다르면 다른 표를 보여 주고 1 로 끝난다.

## 로컬 시험

`local/` 은 Docker 로 NCP 역할 · RDS 역할 MySQL 8.4.11(G1 에서 읽은 운영 값, `local/mysql/g1.cnf`), ProxySQL 3.0.11 두 대,
앱과 같은 Java 25 · HikariCP 7.0.2 · Connector/J 9.7.0 프로브(서비스별 드라이버 옵션의 풀 넷)를 띄운다.
스키마는 be 의 Flyway 마이그레이션(`origin/dev`)을 그대로 적용한다. `apps.sh` 는 실제 be 서비스 이미지(catalog · preorder)를
ProxySQL 뒤에 붙인다.

```sh
scripts/db-migration/local/probe/fetch-deps.sh   # 프로브 jar 받기 (처음 한 번)
scripts/db-migration/local/g3-all.sh             # 빈 환경에서 전 과정 + be 서비스 + 대기 · 재개 + 전환 · 되돌리기 대조
scripts/db-migration/local/faults.sh             # 실패 주입 (g3-all 뒤에)
docker compose -f scripts/db-migration/local/compose.yaml --profile apps down -v   # 정리
```

결과는 `local/work/logs/<시각>/summary.txt` 에 남는다.

시험의 한계: `external_mock` 스키마는 be 의 사본(`docs/external-mock-schema.sql`)으로 만들고 mock 저장소의 Flyway 는 돌리지 않는다.
프로브의 mock 풀은 mock 의 드라이버 옵션만 흉내 내고 `shop` 에 쓴다. `external_mock` 데이터는 덤프 · 되돌리기 체크섬과 `compare` 로 본다.
RDS 프로시저 · NAT 경로 · SSM · ECS 는 로컬에 없어 G2 와 리허설에서 처음 확인한다. `local/work/` (비밀번호 · 덤프 · 결과)와 `local/probe/lib/` 는 git 에 올리지 않는다.

## ProxySQL 에 꼭 필요한 설정

- 감시 전용 그룹(쓰기 그룹 + 1, 운영 11)에 두 서버를 늘 `ONLINE` 으로 둔다. 이 그룹을 쓰는 계정 · 규칙은 없고, ProxySQL 감시가
  계속 접속 · ping 해서 `60` · `70` 이 전환 전에 ProxySQL 에서 받을 서버에 닿는지 본다(받을 서버는 쓰기 그룹에서 빠져 있어 감시되지 않는다). (G3 에서 확인, `60` · `70` 이 사전 확인에서 본다)

- `@@` 변수를 묻는 쿼리는 ProxySQL 의 멀티플렉싱을 끄고, 그 연결이 닫힐 때까지 뒷단 연결이 묶여 `OFFLINE_SOFT` 로 비울 수 없다.
  앱이 보내는 셋에 `multiplex=2` 쿼리 규칙을 둔다.
  - Connector/J 가 연결마다 보내는 `SELECT @@session.auto_increment_increment …` · `SELECT @@session.transaction_read_only`
  - Hibernate 가 기동 때 보내는 `SELECT @@character_set_database, @@sql_mode`. 다이제스트는 쉼표 뒤 공백이 없다
    (`SELECT @@character_set_database,@@sql_mode`)
- `mysql-auto_increment_delay_multiplex=0`. 기본값(5)이면 AUTO_INCREMENT 표(아웃박스)에 쓴 세션이 묶인다.
  앱은 키를 INSERT 응답으로 받으므로(getGeneratedKeys) 끄도록 한다.
- `mysql-connect_timeout_server_max=30000`. 전환 · 되돌리기 동안 쿼리가 오류 대신 기다리는 한도다.

설정 예시는 `local/up.sh` 가 만드는 `proxysql.cnf` 와 같다.
