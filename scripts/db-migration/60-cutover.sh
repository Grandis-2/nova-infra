#!/usr/bin/env bash
# 쓰기 대상을 NCP 에서 RDS 로 넘긴다 (이전 계획 4단계의 db-cutover 런북).
#
#   scripts/db-migration/60-cutover.sh            전환
#   scripts/db-migration/60-cutover.sh recover    실행이 끊긴 뒤(세션 끊김 · kill) 실제 상태를 읽어 한쪽으로 맞춘다
#
#   NCP_* RDS_* RDS_MODE PROXYSQL_* WRITER_SSM_PARAM|WRITER_FILE COORDS_FILE|COORDS_SSM_PARAM (lib.sh)
#   PROXYSQL_FROM · PROXYSQL_TO   ProxySQL 에 등록한 NCP · RDS 주소 (기본 ncp · rds)
#   ACCOUNTS · PW_<계정>          RDS 에 로그인되는지 미리 볼 계정 (20-rds-accounts.sh 와 같은 값)
#   BUDGET_MS        요청이 기다려도 되는 최대 시간 (기본 300). 넘을 것 같으면 NCP 로 되돌리고 다시 시도한다
#   BUDGET_MARGIN_MS 예산 안에서 요청 자체의 처리 시간 · 되돌리는 시간으로 남겨 둘 몫 (기본 50). 앱이 보는 시간이 BUDGET_MS 를
#                    넘지 않게(실패 주입 F9 에서 멈추지 않은 노드가 313ms 를 기다려 30 에서 올렸다)
#   ATTEMPTS · RETRY_GAP_SECONDS   시도 횟수 (기본 5) · 시도 사이 (기본 5)
#   QUIET_WAIT_MS    조용한 순간을 기다리는 시간 (기본 10000)   MAX_LAG_SECONDS  시작 조건의 복제 지연 (기본 5)
#
# 순서. 요청이 ProxySQL 안에서 기다리는 구간은 3 ~ 5 이고, BUDGET_MS 를 넘지 않는다.
#   1. 사전 확인(아무것도 바꾸지 않음): 복제 · 지연, RDS read_only=0, 노드 수와 ProxySQL 필수 설정, 두 서버 이름,
#      RDS 앱 계정 로그인, 쓰기 대상 기록(현재 ncp, 쓸 권한)
#   2. 쓰기 대상 기록을 switching 으로 먼저 바꾸고(운영은 SSM 호출에 1초 안팎이 걸려 대기 구간 밖에서 한다. 그사이 새로 뜨는
#      ProxySQL 태스크는 설정을 만들지 못해 트래픽을 받지 않는다), NCP 에 묶인 뒷단 연결이 0 인 순간을 기다린다
#   3. NCP → OFFLINE_SOFT. 새 쿼리는 ProxySQL 안에서 기다린다
#   4. NCP 에 묶인 연결 0 → NCP gtid_executed 를 읽고 RDS 가 그것까지 적용했는지 본다
#   5. RDS → ONLINE, NCP → OFFLINE_HARD. 기다리던 쿼리가 RDS 로 간다
#   6. RDS 복제를 멈추고, 쓰기 대상 기록을 rds 로 바꾸고, 모든 노드 상태 · 노드 목록을 확인한다
#   7. 4 에서 읽은 뒤 NCP 에 들어온 트랜잭션(ProxySQL 을 거치지 않은 쓰기)이 있으면 그 GTID 를 남기고 3 으로 끝낸다
# 3 ~ 4 가 예산 안에 끝나지 않으면 NCP 로 되돌리고(기다린 요청은 그만큼 늦게 NCP 에서 처리된다) 다시 시도한다.
# 복제는 5 뒤에 멈춘다. 4 에서 RDS 가 따라잡은 것을 확인했고, NCP 는 5 부터 새 쓰기를 받지 않으므로 그 사이에 넘어올 것이 없다.
# 어떻게 끝나든(오류 · 중단) 실제 상태를 읽어 한쪽으로 맞춘다. 프로세스가 강제로 죽으면 recover 로 같은 일을 한다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD
from="${PROXYSQL_FROM:-ncp}"
to="${PROXYSQL_TO:-rds}"
budget="${BUDGET_MS:-300}"
margin="${BUDGET_MARGIN_MS:-50}"
cmd="${1:-run}"
(($# <= 1)) || die "인자가 너무 많다: $*"
ident_ok PROXYSQL_FROM PROXYSQL_TO ACCOUNTS
runbook_lock "$cmd"
guard_rehearsal
# ProxySQL 의 두 서버와 이 스크립트가 직접 붙는 DB 가 같아야 한다(리허설 그룹을 바꾸면서 운영 DB 의 복제를 멈추지 않게)
[[ "$from" == "$NCP_HOST" && "$to" == "$RDS_HOST" ]] || die "PROXYSQL_FROM · TO($from · $to)가 NCP_HOST · RDS_HOST($NCP_HOST · $RDS_HOST)와 다르다"

# 앞으로 맞출 때: RDS 가 NCP 의 트랜잭션을 모두 적용했는지(정상 전환에서는 이미 확인했다) 기다린 뒤 복제를 멈춘다.
# 따라잡지 못한 채 멈추면 빠진 GTID 를 남긴다
stop_replication() {
  local s i caught=0
  if [[ -z "${DUMP_GTID_EXECUTED:-}" ]]; then
    log "경고: 복제 시작점을 읽지 못해 따라잡기를 확인하지 않고 복제를 멈춘다"
  elif sess_q ncp 5000 "SELECT @@global.gtid_executed"; then
    s=${SQ//[$'\n ']/}
    for i in $(seq 50); do
      if sess_q rds 2000 "SELECT GTID_SUBSET(GTID_SUBTRACT('$s', '$DUMP_GTID_EXECUTED'), @@global.gtid_executed)" && [[ "$SQ" == 1 ]]; then
        caught=1
        break
      fi
      sleep 0.2
    done
    ((caught)) || log "경고: RDS 가 NCP 를 다 따라잡지 못한 채 복제를 멈춘다. 빠진 것: $(rds_val "SELECT GTID_SUBTRACT(GTID_SUBTRACT('$s', '$DUMP_GTID_EXECUTED'), @@global.gtid_executed)")"
  else
    log "경고: NCP gtid_executed 를 읽지 못해 따라잡기를 확인하지 않고 복제를 멈춘다 ($SQ)"
  fi
  for i in 1 2 3; do
    if sess_q rds_ctl 10000 "$(repl_stop_sql)" && sess_q rds_ctl 5000 "SELECT COUNT(*) FROM performance_schema.replication_applier_status WHERE SERVICE_STATE='ON'" && [[ "$SQ" == 0 ]]; then
      return 0
    fi
    log "복제 정지 실패($i/3): $SQ"
  done
  return 1
}

# 7단계: 대기를 시작하며 읽은 NCP gtid_executed(얼린 시점) 뒤에 NCP 에 들어온 트랜잭션(ProxySQL 을 거치지 않은 쓰기)을 찾는다.
# 얼린 시점은 파일로 남겨 recover 도 같은 확인을 한다. 있으면 3
freeze_file="$WORK_DIR/cutover-freeze-gtid"
late_check() {
  local freeze late applied
  freeze=$(cat "$freeze_file" 2>/dev/null) || { log "7. 얼린 시점 기록이 없어 확인하지 못했다"; return 0; }
  sess_q ncp 5000 "SELECT @@global.gtid_executed" || { log "7. 경고: NCP 를 읽지 못해 확인하지 못했다($SQ)"; return 1; }
  # 조회가 실패하면 "없음"으로 넘기지 않는다(빈 값은 "들어온 것 없음"과 구분되지 않는다)
  late=$(rds_val "SELECT GTID_SUBTRACT('${SQ//[$'\n ']/}', '$freeze')") || { log "7. 경고: RDS 를 읽지 못해 확인하지 못했다. recover 로 다시 본다"; return 1; }
  if [[ -n "$late" ]]; then
    applied=$(rds_val "SELECT GTID_SUBTRACT('$late', GTID_SUBTRACT('$late', @@global.gtid_executed))") || applied="(읽지 못함)"
    log "7. 경고: 대기 시작 뒤 NCP 에 들어온 트랜잭션 $late (그 가운데 복제로 RDS 에 들어간 것: ${applied:-없음})"
    log "   앱 쓰기라면 RDS 에서 그 데이터를 확인한다. README 의 '종료 코드 3' 절을 따른다"
    return 3
  fi
  log "7. 대기 시작 뒤 NCP 에 들어온 트랜잭션 없음"
}

# 끝날 때 · recover: 실제 상태대로 맞추고, 쓰기 대상 기록과 복제도 그쪽에 맞춘다
phase="before"
settle() { # settle <back|forward|auto>
  local ok=0
  px_settle "$from" "$to" "$1" || ok=1
  if [[ "$SETTLED" == forward ]]; then
    stop_replication || { log "경고: RDS 가 쓰기를 받는데 복제를 멈추지 못했다. $(repl_stop_sql) 을 직접 실행한다"; ok=1; }
    record_writer rds || { log "경고: 쓰기 대상 기록을 rds 로 바꾸지 못했다. ProxySQL 이 재시작하면 NCP 로 간다"; ok=1; }
  elif [[ "$SETTLED" == back ]]; then
    record_writer ncp || { log "경고: 쓰기 대상 기록을 ncp 로 되돌리지 못했다. 새 ProxySQL 태스크가 뜨지 못한다"; ok=1; }
  fi
  px_nodes_check || { log "경고: 노드 목록이 바뀌었다($SQ). 새 노드는 맞추지 않았다. 목록을 다시 받아 recover 를 돌린다"; ok=1; }
  log "정리: ${SETTLED:-판단 못 함} 쪽으로 맞춤 ($( ((ok == 0)) && echo 완료 || echo 일부 실패 — 위 경고 확인))"
  return $ok
}
on_exit() {
  local rc=$1
  case $phase in
    recorded | paused) log "도중에 끝났다. NCP 로 되돌린다"; settle back || rc=1 ;;
    switching) log "전환 도중에 끝났다. 실제 상태를 읽어 맞춘다"; settle auto || rc=1 ;;
  esac
  return "$rc"
}
ON_EXIT=on_exit

# DB 접속은 등록만 해 두고 처음 쓸 때 붙는다. recover 는 NCP · RDS 에 닿지 않아도 노드부터 맞춘다
sess_define ncp "$NCP_HOST" "$NCP_PORT" "$NCP_USER" "$NCP_PASSWORD" REQUIRED
sess_define rds "$RDS_HOST" "$RDS_PORT" "$RDS_USER" "$RDS_PASSWORD" REQUIRED
read -r ctl_host ctl_port ctl_user <<<"$(rds_ctl_args)"
sess_define rds_ctl "$ctl_host" "$ctl_port" "$ctl_user" "$(rds_ctl_password)" REQUIRED
px_open
if [[ "$cmd" == recover ]]; then
  w=$(read_writer 2>/dev/null || true)
  [[ "$w" != switching-ncp ]] || die "쓰기 대상 기록이 switching-ncp 다. 끊긴 것은 되돌리기(70)다. 70-rollback.sh recover 를 돌린다"
  (coords_load) >/dev/null 2>&1 && coords_load || log "경고: 복제 시작점을 읽지 못했다"
  rc=0
  settle auto || rc=1
  # 끊긴 실행이 남긴 SSM 쓰기(aws CLI 는 강제 종료 뒤에도 최대 20초 돈다)가 이 기록을 덮지 않았는지 다시 본다
  [[ -z "${WRITER_SSM_PARAM:-}" ]] || sleep 21
  # 노드를 다 읽지 못해 방향을 정하지 못했으면 기록을 건드리지 않는다(switching 이면 새 태스크가 뜨지 않는 채로 둔다)
  if [[ -n "$SETTLED" ]]; then
    want=$([[ "$SETTLED" == forward ]] && echo rds || echo ncp)
    [[ "$(read_writer)" == "$want" ]] || { log "늦게 끝난 기록이 덮었다. 다시 $want 로 쓴다"; record_writer "$want" || { log "경고: 기록 실패"; rc=1; }; }
    # 끊긴 실행이 남긴 세션이 늦게 실은 노드 변경도 다시 덮는다
    px_settle "$from" "$to" "$SETTLED" || rc=1
    if [[ "$SETTLED" == forward ]]; then late_check || rc=$?; fi
  fi
  exit $rc
fi
[[ "$cmd" == run ]] || die "모르는 명령: $cmd"
need ACCOUNTS
coords_load
sess_must ncp "SELECT 1"
sess_must rds "SELECT 1"
sess_must rds_ctl "SELECT 1"

# ── 1. 사전 확인 ────────────────────────────────────────────
repl=$(rds_ctl -E --column-names <<<"SHOW REPLICA STATUS")
field() { sed -n "s/^ *$1: //p" <<<"$repl"; }
[[ "$(field Replica_IO_Running)" == Yes && "$(field Replica_SQL_Running)" == Yes ]] || die "복제가 돌고 있지 않다"
# 지연 초 값은 1초 단위라 쓰기가 들어오는 동안 0 과 1 을 오간다. 끝까지 따라잡았는지는 4 에서 GTID 로 본다
lag=$(field Seconds_Behind_Source)
[[ "$lag" =~ ^[0-9]+$ ]] && ((lag <= ${MAX_LAG_SECONDS:-5})) || die "복제 지연이 ${MAX_LAG_SECONDS:-5}초를 넘는다 (${lag:-알 수 없음})"
sess_must rds "SELECT @@global.read_only"
[[ "$SQ" == 0 ]] || die "RDS 가 read_only 다. 전환 전에 파라미터 그룹을 read_only=0 으로 둔다"
px_preflight "$from" "$to"
px_state "$from" || die "ProxySQL 상태를 읽지 못했다: $(px_state_text)"
px_all ONLINE || die "$from 이 ONLINE 이 아닌 노드가 있다: $(px_state_text)"
px_state "$to" || die "ProxySQL 상태를 읽지 못했다: $(px_state_text)"
px_all OFFLINE_HARD || die "$to 가 이미 빠져 있지 않은 노드가 있다: $(px_state_text)"
check_logins "$RDS_HOST" "$RDS_PORT"
[[ "$(read_writer)" == ncp ]] || die "쓰기 대상 기록이 ncp 가 아니다: $(read_writer) (switching-* 이면 끊긴 실행이 있었다. 그 스크립트의 recover 를 먼저 돌린다)"
px_reachable "$to"
rm -f "$freeze_file"
record_writer ncp # 같은 값을 다시 써서 쓸 권한 · 도구를 확인한다
log "사전 확인 끝. 복제 Yes/Yes · 지연 ${lag}초, RDS read_only=0, 노드 ${#PX[@]}개 $from ONLINE · $to 빠짐, 앱 계정 로그인 확인"
fault_point preflight

# ── 2 ~ 5 ───────────────────────────────────────────────────
attempt=0
while :; do
  attempt=$((attempt + 1))
  ((attempt <= ${ATTEMPTS:-5})) || die "${ATTEMPTS:-5}번 모두 예산(${budget} ms) 안에 끝나지 않았다. NCP 로 돌아가 있다"

  # 기록을 바꾸기 시작한 때부터는, 실패가 애매해도(시간 초과했지만 실제로는 저장됨) 끝날 때 ncp 로 다시 맞춘다
  phase=recorded
  record_writer switching-rds
  # 이 뒤에 뜨는 태스크는 switching 을 읽어 뜨지 못한다. 그 전에 떠서 ncp 설정을 가진 태스크가 있는지 여기서 본다
  px_nodes_check || die "노드 목록이 바뀌었다($SQ). 목록을 다시 받아 처음부터 한다"
  # 끊겼을 수 있는 세션을 대기 전에 다시 붙여 둔다(인터넷 구간 TLS 재접속이 대기 구간에 들어가지 않게)
  sess_must ncp "SELECT 1"
  sess_must rds "SELECT 1"
  px_wait_quiet "$from"
  phase=paused
  _now
  t0=$NOW
  px_set $((budget - margin)) "$from=OFFLINE_SOFT" || die "3. OFFLINE_SOFT 를 싣지 못한 노드: $PX_FAILED"
  _now
  t1=$NOW
  # 되돌리는 데도 시간이 드므로 방금 바꾸는 데 걸린 시간만큼, 요청 자체의 처리 시간만큼(BUDGET_MARGIN_MS) 예산에서 남겨 둔다
  deadline=$((t0 + budget - (t1 - t0) - margin))
  fault_point paused

  # 남은 예산이 없으면 묻지 않는다(제한 0 으로 물으면 세션만 닫힌다)
  why=""
  used="?"
  while :; do
    _now
    rem=$((deadline - NOW))
    ((rem > 0)) || { why="비우기(묶인 연결 $used)"; break; }
    if px_used "$from" "$rem"; then
      used=$PX_USED
      ((PX_USED != 0)) || break
    else
      used="조회 실패: $(for i in "${!PX[@]}"; do ((PX_RC[i] == 0)) || printf '%s ' "${PX_NODE[$i]}"; done)"
    fi
  done
  _now
  t2=$NOW
  if [[ -z "$why" ]]; then
    rem=$((deadline - NOW))
    if ((rem > 0)) && sess_q ncp "$rem" "SELECT @@global.gtid_executed"; then
      s_final=${SQ//[$'\n ']/}
      printf '%s\n' "$s_final" >"$freeze_file" # 끊겨도 recover 가 7단계를 할 수 있게(로컬 파일이라 대기 구간에 부담이 없다)
      while :; do
        _now
        rem=$((deadline - NOW))
        ((rem > 0)) || { why="따라잡기"; break; }
        if sess_q rds "$rem" "SELECT GTID_SUBSET(GTID_SUBTRACT('$s_final', '$DUMP_GTID_EXECUTED'), @@global.gtid_executed)" && [[ "$SQ" == 1 ]]; then break; fi
      done
    else
      why="NCP gtid_executed 읽기"
    fi
  fi
  _now
  t3=$NOW

  if [[ -n "$why" ]]; then
    settle back || die "되돌리지 못했다. recover 로 다시 맞춘다"
    phase=before
    log "$attempt번째 시도: $why 가 예산을 넘어 NCP 로 되돌렸다(대기 시작부터 모든 노드에 되돌림을 다 싣기까지 약 $((SETTLE_FIRST_MS - t0)) ms. 닿는 노드는 그보다 먼저 풀린다). ${RETRY_GAP_SECONDS:-5}초 뒤 다시"
    sleep "${RETRY_GAP_SECONDS:-5}"
    continue
  fi

  phase=switching
  fault_point switching
  px_set 2000 "$to=ONLINE $from=OFFLINE_HARD" || log "5. 일부 노드에 싣지 못했다: $PX_FAILED (정리에서 다시 맞춘다)"
  _now
  t4=$NOW
  break
done
log "5. $to → ONLINE, $from → OFFLINE_HARD. 요청이 기다린 시간 약 $((t4 - t0)) ms (대기 시작 $((t1 - t0)) · 비우기 $((t2 - t1)) · 따라잡기 $((t3 - t2)) · 전환 $((t4 - t3))), $attempt번째 시도"

# ── 6. 정리와 확인 (대기 구간 밖) ───────────────────────────
fault_point switched
rc=0
settle auto || rc=1
[[ "$SETTLED" == forward ]] || die "전환 확인에서 NCP 쪽으로 맞춰졌다. 상태를 확인한다"
phase="done"
px_save
[[ "$(read_writer)" == rds ]] || { log "경고: 쓰기 대상 기록이 rds 가 아니다"; rc=1; }
log "6. $to 로 맞춤, 복제 멈춤, 쓰기 대상 기록 rds $( ((rc == 0)) && echo "— 모두 확인" || echo "— 일부 실패(위 경고). 7단계 뒤 recover 를 돌린다")"

# ── 7. ProxySQL 을 거치지 않은 NCP 쓰기 ─────────────────────
# NCP 관리 기능이 스스로 남기는 쓰기도 여기에 잡힐 수 있다. 나오면 그 GTID 의 binlog 를 읽어 앱 데이터인지 본다
late_rc=0
late_check || late_rc=$?
((rc == 0)) || log "6단계가 일부 실패했다(위 경고). 아래 종료 코드와 함께 recover 를 돌린다"
((late_rc == 0)) || exit "$late_rc"
((rc == 0)) || exit 1
log "전환 끝. 다음: 40-replication.sh reset(복제 설정 · 비밀번호 지우기)"
