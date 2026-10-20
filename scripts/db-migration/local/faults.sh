#!/usr/bin/env bash
# 실패 주입 시험. g3-all.sh 가 끝난 환경(쓰기 대상 ncp)에서 돈다. 결과는 LOGS(기본 work/logs/faults-<시각>)/summary.txt.
#
#   scripts/db-migration/local/faults.sh
#
# 시나리오마다 런북이 스스로 멈추거나 되돌리는지, 끝난 뒤 두 노드 · 쓰기 대상 기록이 한쪽으로 맞는지 본다.
# 운영에서 일어날 일을 이렇게 흉내 낸다(스크립트의 fault_point 에서 멈춘 사이 호스트가 한다).
#   노드 장애        docker pause (관리 포트와 앱 연결이 함께 멈춘다)
#   실행 중단        tools 컨테이너 안의 런북 프로세스를 kill -9 (SSM 세션 · bastion 을 잃은 것)
#   복제 정지 실패   RDS 에서 런북의 제어 세션을 KILL
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGS="${LOGS:-work/logs/faults-$(date -u +%Y%m%dT%H%M%S)}"
mkdir -p "$LOGS" work/fault
pass=0
fail=0
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOGS/summary.txt" >&2; }
root() { # root <ncp|rds>  (SQL 은 표준 입력)
  docker compose exec -T tools bash -c '
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=\"%s\"\n" "$MYSQL_ROOT_PASSWORD") \
      --host="$0" --ssl-mode=REQUIRED --batch --skip-column-names' "$1"
}
# 두 노드의 상태와 쓰기 대상 기록. 예: "ncp:ONLINE,ONLINE rds:OFFLINE_HARD,OFFLINE_HARD writer:ncp"
state() {
  docker compose exec -T tools bash -c '
    for h in ncp rds; do
      s=""
      for n in proxysql1 proxysql2; do
        s+=$(mysql --defaults-extra-file=<(printf "[client]\nuser=radmin\npassword=\"%s\"\n" "$PW_PROXYSQL_ADMIN") --host=$n --port=6032 --ssl-mode=DISABLED -N -e "SELECT COALESCE(MAX(status), \"OFFLINE_HARD\") FROM runtime_mysql_servers WHERE hostgroup_id=10 AND hostname=\"$h\"")","
      done
      printf "%s:%s " "$h" "${s%,}"
    done'
  printf 'writer:%s' "$(cat work/writer)"
}
WANT_NCP="ncp:ONLINE,ONLINE rds:OFFLINE_HARD,OFFLINE_HARD writer:ncp"
WANT_RDS="ncp:OFFLINE_HARD,OFFLINE_HARD rds:ONLINE,ONLINE writer:rds"
check() { # check <시나리오> <기대 종료 코드: 0 · nonzero> <실제 종료 코드> <기대 상태>
  local got
  got=$(state)
  if { [[ $2 == 0 && $3 == 0 ]] || [[ $2 == nonzero && $3 != 0 ]]; } && [[ "$got" == "$4" ]]; then
    pass=$((pass + 1))
    log "  통과: $1 (종료 $3, $got)"
  else
    fail=$((fail + 1))
    log "  실패: $1 (종료 $3, 기대 $2 · $4, 실제 $got)"
  fi
}
# 런북이 fault_point 에 오면 호스트에서 action 을 돌리고 이어가게 한다
arm() { # arm <action 함수>
  rm -f work/fault/request
  (
    for _ in $(seq 1200); do
      if [[ -e work/fault/request ]]; then
        "$1" || true
        rm -f work/fault/request
        exit 0
      fi
      sleep 0.05
    done
  ) &
  ARM_PID=$!
}
run() { # run <로그 이름> <환경변수...> -- <스크립트> [인자]   종료 코드를 RC 에
  local name=$1
  shift
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  env ${envs[@]+"${envs[@]}"} ./tools.sh "$@" >"$LOGS/$name.log" 2>&1 || RC=$?
  if [[ -n "${ARM_PID:-}" ]]; then
    kill "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
    ARM_PID=""
  fi
}
kill_runbook() { # 런북 프로세스(와 세션 자식)를 강제로 죽인다
  docker compose exec -T -e PAT="/scripts/$1" tools bash -c '
    for p in /proc/[0-9]*; do
      [[ ${p#/proc/} == $$ ]] && continue
      if tr "\0" " " <"$p/cmdline" 2>/dev/null | grep -q "^bash $PAT"; then kill -9 "${p#/proc/}" 2>/dev/null || true; fi
    done'
}
probe_on() { ./probe.sh start "$1"; sleep 5; }
probe_off() { # probe_off <이름> <ncp|rds>
  sleep 5
  ./probe.sh stop "$1"
  ./verify.sh "$2" "$1" >"$LOGS/verify-$1.log" 2>&1 || log "  대조 실패: $1"
  log "  프로브: $(sed -n 's/^확인 응답.*/&/p; s/^쓰기 성공.*/&/p; s/^최대 지연.*/&/p' "$LOGS/verify-$1.log" | tr '\n' ' ')"
}

[[ "$(state)" == "$WANT_NCP" ]] || { echo "쓰기 대상 ncp 상태에서 시작한다: $(state)" >&2; exit 1; }
log "(복제 상태로)"
./reseed.sh >>"$LOGS/reseed.log" 2>&1

log "F1 PROXYSQL_TO 이름이 틀림 → 사전 확인에서 멈추고 아무것도 바꾸지 않는다"
./read-only.sh off >/dev/null
run F1 PROXYSQL_TO=rds-typo -- 60-cutover.sh
check F1 nonzero "$RC" "$WANT_NCP"

log "F2 시작 전에 노드 하나가 응답하지 않음 → 사전 확인에서 멈춘다"
docker pause dbmig-proxysql2-1 >/dev/null
run F2 -- 60-cutover.sh
docker unpause dbmig-proxysql2-1 >/dev/null
check F2 nonzero "$RC" "$WANT_NCP"

log "F3 연결을 고정하는 세션(규칙 없는 @@ 조회)이 열려 있음 → 조용한 순간이 없어 멈춘다"
docker compose exec -d tools bash -c '
  { echo "SELECT @@sql_mode;"; sleep 20; } | mysql --defaults-extra-file=<(printf "[client]\nuser=catalog\npassword=\"%s\"\n" "$PW_CATALOG") --host=proxysql1 --ssl-mode=REQUIRED shop >/dev/null'
sleep 2
run F3 QUIET_WAIT_MS=3000 -- 60-cutover.sh
check F3 nonzero "$RC" "$WANT_NCP"
grep -E '쥔 세션|catalog' "$LOGS/F3.log" | head -3 >>"$LOGS/summary.txt" || true
sleep 18

log "F4 대기 중 노드 하나가 3초 멈춤 → 예산을 넘겨 되돌리고, 다시 시도해 전환한다"
pause_node() { docker pause dbmig-proxysql2-1 >/dev/null; (sleep 3; docker unpause dbmig-proxysql2-1 >/dev/null) & }
probe_on f4
arm pause_node
run F4 FAULT_POINT=paused RETRY_GAP_SECONDS=5 -- 60-cutover.sh
probe_off f4 rds
check F4 0 "$RC" "$WANT_RDS"
grep -E '번째 시도|요청이 기다린 시간' "$LOGS/F4.log" >>"$LOGS/summary.txt" || true

log "R1 되돌리기가 대기 상한을 넘김(WAIT_LIMIT_MS=200) → RDS 로 되돌린다"
run R1 WAIT_LIMIT_MS=200 -- 70-rollback.sh
check R1 nonzero "$RC" "$WANT_RDS"

log "R2 복사 · 체크섬이 끝난 뒤 ProxySQL 을 거치지 않고 RDS 에 씀 → 확인에서 멈추고 RDS 로 되돌린다"
direct_write() { root rds <<<"INSERT INTO shop.g3_probe_outbox (seq) VALUES (-1)"; }
arm direct_write
run R2 FAULT_POINT=checked -- 70-rollback.sh
check R2 nonzero "$RC" "$WANT_RDS"
root rds <<<"DELETE FROM shop.g3_probe_outbox WHERE seq = -1"

log "R3 복사 도중 실행이 죽음 → recover 가 RDS 로 되돌린다"
kill_rollback() { kill_runbook 70-rollback.sh; }
arm kill_rollback
run R3 FAULT_POINT=copying -- 70-rollback.sh
run R3-recover -- 70-rollback.sh recover
check R3 0 "$RC" "$WANT_RDS"

log "R4 정상 되돌리기"
probe_on r4
run R4 -- 70-rollback.sh
probe_off r4 ncp
check R4 0 "$RC" "$WANT_NCP"

log "(다시 복제 상태로)"
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F5 따라잡기가 늦음(RDS SQL 스레드 4초 멈춤) → 예산을 넘겨 되돌리고, 다시 시도해 전환한다"
# 프로브 스레드는 같은 순간에 몰아 쓰므로, 멈춘 뒤 NCP 쓰기가 반드시 있게 하나를 직접 넣는다
stop_sql() { root rds <<<"STOP REPLICA SQL_THREAD"; root ncp <<<"INSERT INTO shop.g3_probe_outbox (seq) VALUES (-3)"; (sleep 4; root rds <<<"START REPLICA SQL_THREAD") & }
probe_on f5
arm stop_sql
run F5 FAULT_POINT=preflight RETRY_GAP_SECONDS=5 -- 60-cutover.sh
probe_off f5 rds
check F5 0 "$RC" "$WANT_RDS"
grep -E '번째 시도|요청이 기다린 시간' "$LOGS/F5.log" >>"$LOGS/summary.txt" || true
./tools.sh 70-rollback.sh >"$LOGS/F5-rollback.log" 2>&1
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F6 대기 중 실행이 죽음 → NCP 가 OFFLINE_SOFT 로 남는다 → recover 가 NCP 로 되돌린다"
kill_cutover() { kill_runbook 60-cutover.sh; }
probe_on f6
arm kill_cutover
run F6 FAULT_POINT=paused -- 60-cutover.sh
log "  죽은 직후: $(state)"
run F6-recover -- 60-cutover.sh recover
probe_off f6 ncp
check F6 0 "$RC" "$WANT_NCP"

log "F7 전환 직후(복제 정지 전) 실행이 죽음 → recover 가 앞으로 맞추고 복제를 멈춘다"
arm kill_cutover
run F7 FAULT_POINT=switched -- 60-cutover.sh
log "  죽은 직후: $(state)"
run F7-recover -- 60-cutover.sh recover
check F7 0 "$RC" "$WANT_RDS"
log "  RDS 복제 SQL 스레드: $(root rds <<<"SELECT SERVICE_STATE FROM performance_schema.replication_applier_status")"
./tools.sh 70-rollback.sh >"$LOGS/F7-rollback.log" 2>&1
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F12 전환 직후 실행이 죽고, 한 노드에서 RDS 가 SHUNNED 가 됨 → recover 가 NCP 로 되돌리지 않고 앞으로 맞춘다"
shun_and_kill() {
  kill_runbook 60-cutover.sh
  docker compose exec -T tools bash -c 'mysql --defaults-extra-file=<(printf "[client]\nuser=radmin\npassword=\"%s\"\n" "$PW_PROXYSQL_ADMIN") --host=proxysql1 --port=6032 --ssl-mode=DISABLED -e "UPDATE mysql_servers SET status=\"SHUNNED\" WHERE hostgroup_id=10 AND hostname=\"rds\"; LOAD MYSQL SERVERS TO RUNTIME"'
}
arm shun_and_kill
run F12 FAULT_POINT=switched -- 60-cutover.sh
log "  죽은 직후: $(state)"
run F12-recover -- 60-cutover.sh recover
check F12 0 "$RC" "$WANT_RDS"
./tools.sh 70-rollback.sh >"$LOGS/F12-rollback.log" 2>&1
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F8 전환 뒤 복제 정지 세션이 끊김 → 다시 붙어 멈춘다"
kill_ctl() { root rds <<<"SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist WHERE user = 'root' AND id <> CONNECTION_ID()" | root rds; }
arm kill_ctl
run F8 FAULT_POINT=switched -- 60-cutover.sh
check F8 0 "$RC" "$WANT_RDS"
grep -E '복제 정지 실패' "$LOGS/F8.log" >>"$LOGS/summary.txt" || true
./tools.sh 70-rollback.sh >"$LOGS/F8-rollback.log" 2>&1

./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F9 대기 중 첫 노드(proxysql1)가 3초 멈춤 → 다른 노드는 예산 안에 풀리고, 다시 시도해 전환한다"
pause_first() { docker pause dbmig-proxysql1-1 >/dev/null; (sleep 3; docker unpause dbmig-proxysql1-1 >/dev/null) & }
probe_on f9
arm pause_first
run F9 FAULT_POINT=paused RETRY_GAP_SECONDS=5 -- 60-cutover.sh
probe_off f9 rds
check F9 0 "$RC" "$WANT_RDS"
grep -E '번째 시도|요청이 기다린 시간' "$LOGS/F9.log" >>"$LOGS/summary.txt" || true
log "  풀별 최대 지연(proxysql2 = catalog · mock): $(awk -F'\t' 'NR>1 {ms=$5/1000; if (ms>m[$2]) m[$2]=ms} END {for (p in m) printf "%s %.0fms ", p, m[p]}' work/f9/events.tsv)"
./tools.sh 70-rollback.sh >"$LOGS/F9-rollback.log" 2>&1
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "F10 전환이 도는 동안 recover 를 겹쳐 돌림 → 잠금 때문에 recover 가 멈춘다"
overlap() { ./tools.sh 60-cutover.sh recover >"$LOGS/F10-recover.log" 2>&1 && echo 0 >work/fault/overlap-rc || echo $? >work/fault/overlap-rc; }
arm overlap
run F10 FAULT_POINT=preflight -- 60-cutover.sh
check F10 0 "$RC" "$WANT_RDS"
if [[ "$(cat work/fault/overlap-rc)" != 0 ]] && grep -q '다른 런북 실행' "$LOGS/F10-recover.log"; then
  pass=$((pass + 1)); log "  통과: F10 겹친 recover 는 잠금으로 멈췄다"
else
  fail=$((fail + 1)); log "  실패: F10 겹친 recover 가 돌았다"
fi
./tools.sh 70-rollback.sh >"$LOGS/F10-rollback.log" 2>&1
./reseed.sh >>"$LOGS/reseed.log" 2>&1
./read-only.sh off >/dev/null

log "H1 리허설(B: 리허설 NCP + 아직 비어 있는 운영 RDS): 그룹 20 에서 전환해도 운영 그룹(10) · 운영 기록은 그대로다"
root ncp <<<"CREATE USER IF NOT EXISTS 'rehearsal_probe'@'%' IDENTIFIED BY 'Rehearsal-Probe-1'; GRANT SELECT, INSERT ON shop.* TO 'rehearsal_probe'@'%'"
rh=(PROXYSQL_HOSTGROUP=20 NCP_HOST=ncp-rehearsal RDS_HOST=rds REHEARSAL_NCP_HOST=ncp-rehearsal REHEARSAL_RDS_HOST=rds REHEARSAL_USER=rehearsal_probe REHEARSAL_PASSWORD=Rehearsal-Probe-1)
run H1-setup "${rh[@]}" -- 50-rehearsal-proxysql.sh setup
run H1-host "${rh[@]}" NCP_HOST=ncp WRITER_FILE=/work/rehearsal-writer PROXYSQL_FROM=rds PROXYSQL_TO=ncp-rehearsal -- 70-rollback.sh
if [[ $RC != 0 ]] && grep -q 'RDS_HOST · NCP_HOST' "$LOGS/H1-host.log"; then pass=$((pass + 1)); log "  통과: 리허설 그룹에 운영 DB 주소를 주면 되돌리기가 멈춘다"; else fail=$((fail + 1)); log "  실패: 리허설 주소 가드"; fi
run H1-guard "${rh[@]}" WRITER_SSM_PARAM=/nova-prod/db-migration/writer PROXYSQL_FROM=ncp-rehearsal PROXYSQL_TO=rds -- 60-cutover.sh
if [[ $RC != 0 ]] && grep -q '리허설이다' "$LOGS/H1-guard.log"; then pass=$((pass + 1)); log "  통과: 운영 SSM 기록을 주면 리허설 전환이 멈춘다"; else fail=$((fail + 1)); log "  실패: 리허설 가드"; fi
echo ncp >work/rehearsal-writer
run H1 "${rh[@]}" WRITER_FILE=/work/rehearsal-writer PROXYSQL_FROM=ncp-rehearsal PROXYSQL_TO=rds -- 60-cutover.sh
check H1 0 "$RC" "$WANT_NCP"
log "  리허설 기록: $(cat work/rehearsal-writer)"
run H1-clean-guard "${rh[@]}" -- 50-rehearsal-proxysql.sh clean-rds
if [[ $RC != 0 ]] && grep -q '복제하고 있다\|read_only=1' "$LOGS/H1-clean-guard.log"; then pass=$((pass + 1)); log "  통과: 운영 NCP 를 복제 중인 RDS 는 clean-rds 가 비우지 않는다"; else fail=$((fail + 1)); log "  실패: clean-rds 가드"; fi
./tools.sh 40-replication.sh reset >/dev/null 2>&1
./read-only.sh off >/dev/null
# 실제 덤프를 적재한 뒤 복제를 걸기 전과 같은 상태(복제 설정 없음 · read_only=0). 리허설 표식이 없으면 지우지 않아야 한다
run H1-clean-nomark "${rh[@]}" -- 50-rehearsal-proxysql.sh clean-rds
if [[ $RC != 0 ]] && grep -q '리허설 표식' "$LOGS/H1-clean-nomark.log"; then pass=$((pass + 1)); log "  통과: 리허설 표식이 없는 RDS(실제 적재일 수 있음)는 clean-rds 가 비우지 않는다"; else fail=$((fail + 1)); log "  실패: 표식 없는 clean-rds"; fi
root rds <<<"CREATE DATABASE db_migration_rehearsal" # 리허설 30 이 남기는 표식
run H1-clean "${rh[@]}" -- 50-rehearsal-proxysql.sh clean-rds
if [[ $RC == 0 && "$(root rds <<<"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('shop', 'external_mock')")" == 0 ]]; then pass=$((pass + 1)); log "  통과: 리허설 뒤 clean-rds 가 운영 RDS 를 비운다"; else fail=$((fail + 1)); log "  실패: clean-rds"; fi
run H1-teardown "${rh[@]}" -- 50-rehearsal-proxysql.sh teardown
./reseed.sh >>"$LOGS/reseed.log" 2>&1

log "F11 실제 노드 목록이 받은 목록과 다름(태스크가 바뀜) → 시작하지 않는다"
run F11 PROXYSQL_NODES_CMD="echo proxysql1:6032; echo proxysql3:6032" -- 60-cutover.sh
check F11 nonzero "$RC" "$WANT_NCP"
grep -q '노드 목록이 실제와 다르다' "$LOGS/F11.log" || { fail=$((fail + 1)); log "  실패: F11 메시지"; }

log "F13 ProxySQL 에서 RDS 에 닿지 않음(감시 그룹의 RDS 포트를 틀리게) → 사전 확인에서 멈춘다"
admin_all() { docker compose exec -T tools bash -c 'for n in proxysql1 proxysql2; do mysql --defaults-extra-file=<(printf "[client]\nuser=radmin\npassword=\"%s\"\n" "$PW_PROXYSQL_ADMIN") --host=$n --port=6032 --ssl-mode=DISABLED -e "$0"; done' "$1"; }
./read-only.sh off >/dev/null
admin_all "UPDATE mysql_servers SET port=3307 WHERE hostgroup_id=11 AND hostname='rds'; LOAD MYSQL SERVERS TO RUNTIME"
sleep 8
run F13 MONITOR_WAIT_SECONDS=5 -- 60-cutover.sh
admin_all "UPDATE mysql_servers SET port=3306 WHERE hostgroup_id=11 AND hostname='rds'; LOAD MYSQL SERVERS TO RUNTIME"
check F13 nonzero "$RC" "$WANT_NCP"
grep -q '닿지 않는다' "$LOGS/F13.log" || { fail=$((fail + 1)); log "  실패: F13 메시지"; }
sleep 8

log "F14 되돌리기(70)가 끊긴 기록(switching-ncp)인데 60 recover 를 돌림 → 멈추고 70 recover 를 알려 준다"
echo switching-ncp >work/writer
run F14 -- 60-cutover.sh recover
echo ncp >work/writer
check F14 nonzero "$RC" "$WANT_NCP"
grep -q '70-rollback.sh recover' "$LOGS/F14.log" || { fail=$((fail + 1)); log "  실패: F14 메시지"; }

log "C1 같은 시점 비교: 조용할 때 같다, RDS 에 직접 쓰면 다른 표를 짚는다"
run C1 -- 40-replication.sh compare
check C1 0 "$RC" "$WANT_NCP"
root rds <<<"INSERT INTO shop.g3_probe_outbox (seq) VALUES (-9)"
run C1-diff -- 40-replication.sh compare
root rds <<<"DELETE FROM shop.g3_probe_outbox WHERE seq = -9"
if [[ $RC != 0 ]] && grep -q 'shop.g3_probe_outbox' "$LOGS/C1-diff.log"; then pass=$((pass + 1)); log "  통과: 다른 표(g3_probe_outbox)를 짚었다"; else fail=$((fail + 1)); log "  실패: 비교가 차이를 못 잡았다"; fi

log "D1 덤프 직전에 오래 도는 문장 → 덤프하지 않는다"
LOAD=0 ./reseed.sh >>"$LOGS/reseed.log" 2>&1
log "D0 리허설 표식이 남은 RDS 에 실제 30 → 멈춘다(clean-rds 를 먼저)"
root rds <<<"CREATE DATABASE IF NOT EXISTS db_migration_rehearsal"
run D0 -- 30-dump-load.sh
root rds <<<"DROP DATABASE IF EXISTS db_migration_rehearsal"
if [[ $RC != 0 ]] && grep -q '리허설 표식' "$LOGS/D0.log"; then pass=$((pass + 1)); log "  통과: D0"; else fail=$((fail + 1)); log "  실패: D0"; fi
root ncp <<<"SELECT SLEEP(4)" >/dev/null &
sleep 2
run D1 -- 30-dump-load.sh
wait
check D1 nonzero "$RC" "$WANT_NCP"

log "D2 덤프 직전 긴 SELECT 가 시작됨 → 덤프 계정의 LOCK TABLES READ 는 SELECT 를 기다리지 않아 쓰기가 막히지 않는다"
long_select() { root ncp <<<"SELECT SLEEP(3) FROM shop.g3_probe_counter" >/dev/null & sleep 0.3; }
probe_on d2
arm long_select
run D2 FAULT_POINT=before_dump -- 30-dump-load.sh
probe_off d2 ncp
check D2 0 "$RC" "$WANT_NCP"
LOAD=0 ./reseed.sh >>"$LOGS/reseed.log" 2>&1

log "D3 덤프 직전 쓰기 트랜잭션이 열려 있음 → 표 잠금이 그 뒤에서 기다리며 쓰기를 막으면 200ms 에 덤프를 끊는다"
open_tx() { root ncp <<<"BEGIN; INSERT INTO shop.g3_probe_outbox (seq) VALUES (-2); SELECT SLEEP(3); ROLLBACK;" >/dev/null & sleep 0.3; }
probe_on d3
arm open_tx
run D3 FAULT_POINT=before_dump -- 30-dump-load.sh
probe_off d3 ncp
check D3 nonzero "$RC" "$WANT_NCP"
grep -E '덤프 세션|끊었다' "$LOGS/D3.log" >>"$LOGS/summary.txt" || true
log "  RDS 표 수(0 이어야 한다): $(root rds <<<"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('shop', 'external_mock')")"

log "(다시 복제 상태로)"
./reseed.sh >>"$LOGS/reseed.log" 2>&1
log "끝. 통과 $pass · 실패 $fail. 상태 $(state)"
((fail == 0))
