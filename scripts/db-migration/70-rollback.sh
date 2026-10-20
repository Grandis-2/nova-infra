#!/usr/bin/env bash
# 쓰기 대상을 RDS 에서 NCP 로 되돌린다 (이전 계획 5단계의 db-rollback 런북, 전환 뒤 NCP 를 내리기 전까지만 쓴다).
# 오류를 감수하는 비상 경로다. RDS 를 NCP 로 통째로 복사하는 동안(운영 추정 10 ~ 20초) 요청이 ProxySQL 안에서 기다리고,
# 그동안 앱의 시간 제한(서비스 간 호출 1초 · preorder 연결 대기 2초)에 걸리는 요청은 실패한다.
#
#   scripts/db-migration/70-rollback.sh            되돌리기
#   scripts/db-migration/70-rollback.sh recover    실행이 끊긴 뒤 실제 상태를 읽어 한쪽으로 맞춘다
#
#   NCP_HOST NCP_PORT NCP_MIGRATOR_USER(기본 nova_migrator) NCP_MIGRATOR_PASSWORD   NCP 에 적재할 DDL 계정
#   RDS_* PROXYSQL_* WRITER_SSM_PARAM|WRITER_FILE (lib.sh)   PROXYSQL_FROM(기본 rds) PROXYSQL_TO(기본 ncp)
#   ACCOUNTS · PW_<계정>   NCP 에 로그인되는지 미리 볼 계정
#   APP_SCHEMAS (기본 shop external_mock)   COPY_DIR (기본 $WORK_DIR/rollback-<시각>, 끝나면 지운다. KEEP_COPY=1 이면 남긴다)
#   DRAIN_TIMEOUT_MS (기본 2000)   WAIT_LIMIT_MS: 대기 시작부터 전환까지의 상한 (기본 25000, ProxySQL 의 30초 대기 한도 안쪽)
#
# 순서. 요청이 기다리는 구간은 3 ~ 6 이다.
#   1. 사전 확인(아무것도 바꾸지 않음): 노드 수 · ProxySQL 설정 · 두 서버 이름, NCP 적재 계정과 앱 계정 로그인, 쓰기 대상 기록,
#      복사할 곳의 여유 공간, ProxySQL 대기 한도
#   2. 쓰기 대상 기록을 switching 으로 두고(되돌리는 동안 새로 뜨는 ProxySQL 태스크가 트래픽을 받지 않게) RDS 에 묶인 연결이
#      0 인 순간을 기다린다
#   3. RDS → OFFLINE_SOFT, 묶인 연결 0 까지 기다린다
#   4. RDS gtid_executed 를 적어 두고, DB 마다 RDS 를 mysqldump(--single-transaction) 해서 NCP 에 적재한다. 표를 지우고 다시
#      만들며, 덤프가 FK 검사를 끈다. NCP 에서는 DB 를 만들 수 없으므로 --databases 없이 표만 옮긴다
#   5. 표마다 CHECKSUM TABLE 을 비교한다. RDS gtid_executed 가 4 에서 늘었으면 RDS 표를 다시 재서 그대로인지 본다
#      (ProxySQL 을 거치지 않은 RDS 쓰기. RDS 가 스스로 남기는 기록만으로도 GTID 는 늘 수 있다)
#   6. NCP → ONLINE, RDS → OFFLINE_HARD, 쓰기 대상 기록 ncp
# 어느 단계든 실패하거나 WAIT_LIMIT_MS 를 넘으면 RDS 를 다시 ONLINE 으로 둔다(NCP 의 표는 반쯤 덮인 채 남는다. 다시 돌리면 덮는다).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need NCP_HOST NCP_PORT NCP_MIGRATOR_PASSWORD RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD
from="${PROXYSQL_FROM:-rds}"
to="${PROXYSQL_TO:-ncp}"
limit_ms="${WAIT_LIMIT_MS:-25000}"
read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
copy_dir="${COPY_DIR:-$WORK_DIR/rollback-$(date -u +%Y%m%dT%H%M%S)}"
mig_user="${NCP_MIGRATOR_USER:-nova_migrator}"
cmd="${1:-run}"
(($# <= 1)) || die "인자가 너무 많다: $*"
ident_ok PROXYSQL_FROM PROXYSQL_TO ACCOUNTS APP_SCHEMAS
runbook_lock "$cmd"
guard_rehearsal
# ProxySQL 의 두 서버와 이 스크립트가 복사하는 DB 가 같아야 한다(리허설 그룹을 바꾸면서 운영 NCP 를 덮지 않게)
[[ "$from" == "$RDS_HOST" && "$to" == "$NCP_HOST" ]] || die "PROXYSQL_FROM · TO($from · $to)가 RDS_HOST · NCP_HOST($RDS_HOST · $NCP_HOST)와 다르다"
ncp_mig() { _mysql "$NCP_HOST" "$NCP_PORT" "$mig_user" "$NCP_MIGRATOR_PASSWORD" REQUIRED "$@"; }

phase="before"
settle() { # settle <back|auto>
  local ok=0
  px_settle "$from" "$to" "$1" || ok=1
  case $SETTLED in
    forward) record_writer ncp || { log "경고: 쓰기 대상 기록을 ncp 로 바꾸지 못했다. 새 ProxySQL 태스크가 뜨지 못한다"; ok=1; } ;;
    back) record_writer rds || { log "경고: 쓰기 대상 기록을 rds 로 되돌리지 못했다. 새 ProxySQL 태스크가 뜨지 못한다"; ok=1; } ;;
  esac
  px_nodes_check || { log "경고: 노드 목록이 바뀌었다($SQ). 새 노드는 맞추지 않았다. 목록을 다시 받아 recover 를 돌린다"; ok=1; }
  log "정리: ${SETTLED:-판단 못 함} 쪽으로 맞춤 ($( ((ok == 0)) && echo 완료 || echo 일부 실패 — 위 경고 확인))"
  return $ok
}
on_exit() {
  local rc=$1
  case $phase in
    paused | recorded) log "도중에 끝났다. RDS 로 되돌린다"; settle back || rc=1 ;;
    switching) log "전환 도중에 끝났다. 실제 상태를 읽어 맞춘다"; settle auto || rc=1 ;;
  esac
  [[ "${KEEP_COPY:-}" == 1 || ! -d "$copy_dir" ]] || rm -rf "$copy_dir"
  return "$rc"
}
ON_EXIT=on_exit

px_open
if [[ "$cmd" == recover ]]; then
  w=$(read_writer 2>/dev/null || true)
  [[ "$w" != switching-rds ]] || die "쓰기 대상 기록이 switching-rds 다. 끊긴 것은 전환(60)이다. 60-cutover.sh recover 를 돌린다"
  rc=0
  settle auto || rc=1
  # 끊긴 실행이 남긴 SSM 쓰기(aws CLI 는 강제 종료 뒤에도 최대 20초 돈다)가 이 기록을 덮지 않았는지 다시 본다
  [[ -z "${WRITER_SSM_PARAM:-}" ]] || sleep 21
  # 노드를 다 읽지 못해 방향을 정하지 못했으면 기록을 건드리지 않는다(switching 이면 새 태스크가 뜨지 않는 채로 둔다)
  if [[ -n "$SETTLED" ]]; then
    want=$([[ "$SETTLED" == forward ]] && echo ncp || echo rds)
    [[ "$(read_writer)" == "$want" ]] || { log "늦게 끝난 기록이 덮었다. 다시 $want 로 쓴다"; record_writer "$want" || { log "경고: 기록 실패"; rc=1; }; }
    px_settle "$from" "$to" "$SETTLED" || rc=1 # 끊긴 실행이 남긴 세션이 늦게 실은 노드 변경도 다시 덮는다
  fi
  exit $rc
fi
[[ "$cmd" == run ]] || die "모르는 명령: $cmd"
need ACCOUNTS
rds_open

# ── 1. 사전 확인 ────────────────────────────────────────────
px_preflight "$from" "$to"
px_state "$from" || die "ProxySQL 상태를 읽지 못했다: $(px_state_text)"
# RDS 가 SHUNNED(연결 오류로 잠깐 쉼)여도 되돌릴 수 있어야 한다. 빠져 있거나 비우는 중이면 멈춘다
! px_any OFFLINE_HARD && ! px_any OFFLINE_SOFT || die "$from 이 들어가 있지 않은 노드가 있다: $(px_state_text)"
px_state "$to" || die "ProxySQL 상태를 읽지 못했다: $(px_state_text)"
px_all OFFLINE_HARD || die "$to 가 이미 빠져 있지 않은 노드가 있다: $(px_state_text)"
grants=$(ncp_mig <<<"SHOW GRANTS") || die "NCP $mig_user 로 접속하지 못했다"
for s in "${schemas[@]}"; do
  grep -Eq "GRANT ALL PRIVILEGES ON \`$s\`\.\*" <<<"$grants" || die "NCP $mig_user 에 $s 의 ALL 권한이 없다"
done
check_logins "$NCP_HOST" "$NCP_PORT"
[[ "$(read_writer)" == rds ]] || die "쓰기 대상 기록이 rds 가 아니다: $(read_writer) (switching-* 이면 끊긴 실행이 있었다. 그 스크립트의 recover 를 먼저 돌린다)"
px_reachable "$to"
# 복사할 곳: RDS 두 DB 크기의 3배는 비어 있어야 한다(덤프 파일 · 체크섬). 모자라면 요청을 기다리게 한 채 실패한다
need_kb=$(rds_val "SELECT CEIL(COALESCE(SUM(data_length + index_length), 0) * 3 / 1024) FROM information_schema.tables WHERE table_schema IN ($(printf "'%s'," "${schemas[@]}" | sed 's/,$//'))")
mkdir -p "$copy_dir"
free_kb=$(df -Pk "$copy_dir" | awk 'NR == 2 {print $4}')
((free_kb > need_kb)) || die "$copy_dir 의 여유 공간(${free_kb}KB)이 필요한 만큼(${need_kb}KB) 없다"
# 복사하는 동안 쿼리가 ProxySQL 안에서 기다릴 수 있는 한도가 이 스크립트의 상한보다 길어야 한다
for i in "${!PX[@]}"; do
  sess_must "${PX[$i]}" "SELECT variable_value FROM runtime_global_variables WHERE variable_name='mysql-connect_timeout_server_max'"
  ((SQ >= limit_ms + 3000)) || die "${PX_NODE[$i]} mysql-connect_timeout_server_max=$SQ 가 WAIT_LIMIT_MS($limit_ms)+3000 보다 짧다"
done
record_writer rds # 같은 값을 다시 써서 쓸 권한 · 도구를 확인한다
log "사전 확인 끝. 노드 ${#PX[@]}개 $from ONLINE · $to 빠짐, NCP $mig_user 권한 · 앱 계정 로그인 확인"
fault_point preflight

# ── 2 ~ 3 ───────────────────────────────────────────────────
# 기록을 switching 으로 두면 되돌리는 동안 새로 뜨는 ProxySQL 태스크가 트래픽을 받지 않는다
phase=recorded
record_writer switching-ncp
# 이 뒤에 뜨는 태스크는 switching 을 읽어 뜨지 못한다. 그 전에 떠서 rds 설정을 가진 태스크가 있는지 여기서 본다
px_nodes_check || die "노드 목록이 바뀌었다($SQ). 목록을 다시 받아 처음부터 한다"
px_wait_quiet "$from"
phase=paused
t0=$(ms)
px_set 2000 "$from=OFFLINE_SOFT" || die "3. OFFLINE_SOFT 를 싣지 못한 노드: $PX_FAILED"
until px_used "$from" 1000 && ((PX_USED == 0)); do
  (($(ms) - t0 < ${DRAIN_TIMEOUT_MS:-2000})) || die "3. $from 연결 비우기가 ${DRAIN_TIMEOUT_MS:-2000} ms 를 넘었다"
done
t1=$(ms)
log "3. $from → OFFLINE_SOFT, 묶인 연결 0 ($((t1 - t0)) ms). 새 쿼리는 대기"

# ── 4. 복사 ─────────────────────────────────────────────────
left() { echo $(((limit_ms - ($(ms) - t0)) / 1000)); }          # 남은 초 (0 이면 상한을 넘은 것)
cap() { local l; l=$(left); echo $((l < 1 ? 1 : l)); }        # 호출에 줄 제한(초). timeout 0 은 제한 없음이라 1 이상으로
sess_must rds "SELECT @@global.gtid_executed"
g0=${SQ//[$'\n ']/}
fault_point copying
for s in "${schemas[@]}"; do
  (($(left) > 0)) || die "4. 대기 상한 ${limit_ms} ms 를 넘었다"
  # BINARY(16) UUID 칼럼이 있어 --hex-blob 으로 옮긴다. 비밀번호는 lib.sh 와 같은 방식으로 넘긴다
  timeout "$(cap)" mysqldump --defaults-extra-file=<(printf '[client]\nuser="%s"\npassword="%s"\n' "$RDS_USER" "$RDS_PASSWORD") \
    --host="$RDS_HOST" --port="$RDS_PORT" --ssl-mode=REQUIRED --default-character-set=utf8mb4 \
    --single-transaction --set-gtid-purged=OFF --no-tablespaces --hex-blob --routines --events --triggers \
    "$s" >"$copy_dir/$s.sql" || die "4. $s 덤프 실패 또는 시간 초과"
  (($(left) > 0)) || die "4. 대기 상한 ${limit_ms} ms 를 넘었다"
  MYSQL_CALL_TIMEOUT=$(cap) ncp_mig --database="$s" <"$copy_dir/$s.sql" || die "4. $s 적재 실패 또는 시간 초과"
done
t2=$(ms)
log "4. RDS → NCP 복사 ($((t2 - t1)) ms, $(du -sh "$copy_dir" | cut -f1))"

# ── 5. 확인 ─────────────────────────────────────────────────
checksums() { # checksums <ncp_mig|rds> <DB>   호출마다 남은 시간을 제한으로 준다
  local tables
  tables=$(MYSQL_CALL_TIMEOUT=$(cap) "$1" <<<"SET SESSION group_concat_max_len = 1000000;
    SELECT GROUP_CONCAT(CONCAT('\`', table_schema, '\`.\`', table_name, '\`') ORDER BY table_name) FROM information_schema.tables WHERE table_schema='$2' AND table_type='BASE TABLE'") || return 1 # 실패를 빈 값(표 없음)으로 넘기지 않는다
  [[ -z "$tables" || "$tables" == NULL ]] && return 0
  MYSQL_CALL_TIMEOUT=$(cap) "$1" <<<"CHECKSUM TABLE $tables"
}
for s in "${schemas[@]}"; do
  (($(left) > 0)) || die "5. 대기 상한 ${limit_ms} ms 를 넘었다"
  # diff 가 없는 환경(mysql 이미지)도 있어 문자열로 비교하고, 다르면 양쪽을 파일로 남긴다
  want=$(checksums rds "$s") || die "5. $s RDS 체크섬 실패"
  got=$(checksums ncp_mig "$s") || die "5. $s NCP 체크섬 실패"
  printf '%s\n' "$want" >"$copy_dir/$s.checksum"
  if [[ "$want" != "$got" ]]; then
    KEEP_COPY=1
    printf '%s\n' "$want" >"$copy_dir/$s.checksum.rds"
    printf '%s\n' "$got" >"$copy_dir/$s.checksum.ncp"
    die "5. $s 체크섬이 다르다 ($copy_dir/$s.checksum.rds · .ncp)"
  fi
done
fault_point checked
# RDS 는 스스로 남기는 기록(관리 프로시저 등)으로 GTID 가 늘 수 있다. 늘었으면 RDS 의 표를 다시 재서 복사본과 같은지 본다
SESSION_QUERY_TIMEOUT_MS=$(($(cap) * 1000)) sess_must rds "SELECT @@global.gtid_executed"
g1=${SQ//[$'\n ']/}
if [[ "$g1" != "$g0" ]]; then
  log "5. 복사하는 동안 RDS gtid_executed 가 늘었다($g0 → $g1). 표를 다시 잰다"
  for s in "${schemas[@]}"; do
    (($(left) > 0)) || die "5. 대기 상한 ${limit_ms} ms 를 넘었다"
    again=$(checksums rds "$s") || die "5. $s RDS 체크섬을 다시 재지 못했다"
    [[ "$again" == "$(cat "$copy_dir/$s.checksum" 2>/dev/null)" ]] ||
      die "5. 복사하는 동안 RDS $s 에 ProxySQL 을 거치지 않은 쓰기가 있었다"
  done
fi
t3=$(ms)
(($(ms) - t0 < limit_ms)) || die "5. 대기 상한 ${limit_ms} ms 를 넘었다"
log "5. 표마다 체크섬 일치, 복사 중 RDS 변화 없음 ($((t3 - t2)) ms)"

# ── 6. 전환 ─────────────────────────────────────────────────
phase=switching
px_set 2000 "$to=ONLINE $from=OFFLINE_HARD" || log "6. 일부 노드에 싣지 못했다: $PX_FAILED (정리에서 다시 맞춘다)"
t4=$(ms)
settle auto || die "노드 · 기록을 맞추지 못했다(위 경고). recover 로 다시 맞춘다"
[[ "$SETTLED" == forward ]] || die "전환 확인에서 RDS 쪽으로 맞춰졌다. 상태를 확인한다"
phase="done"
px_save
log "6. $to → ONLINE, $from → OFFLINE_HARD. 쓰기 대상 기록 ncp"
log "되돌리기 끝. 요청이 기다린 시간 약 $((t4 - t0)) ms (비우기 $((t1 - t0)) · 복사 $((t2 - t1)) · 확인 $((t3 - t2)) · 전환 $((t4 - t3)))"
log "다음: Flyway · exporter 주소를 NCP 로 되돌리는 PR 전까지 be · mock 릴리스를 멈춰 둔다. RDS 를 read_only=1 로 둔다"
