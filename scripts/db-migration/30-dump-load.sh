#!/usr/bin/env bash
# NCP 의 옮길 DB 를 MySQL Shell 로 덤프해 RDS 에 적재하고, 복제를 시작할 binlog 위치를 남긴다 (이전 계획 1단계 5번).
#
#   NCP_HOST NCP_PORT DUMP_USER(기본 dump_rds) DUMP_PASSWORD   덤프 계정 (10-ncp-users.sh 가 만든다)
#   RDS_* (마스터)   COORDS_FILE · COORDS_SSM_PARAM (lib.sh)
#   DUMP_DIR          덤프를 둘 경로(없거나 빈 디렉터리) (기본: $WORK_DIR/dump-<시각>). 어떻게 끝나든 지운다(KEEP_DUMP=1 이면 남긴다)
#   APP_SCHEMAS       옮길 DB (기본: shop external_mock)
#   LONG_STMT_SECONDS 덤프 직전 NCP 에 이보다 오래 도는 문장이 있으면 시작하지 않는다 (기본 1)
#   LOCK_WAIT_MAX_MS  덤프 시작 잠금 때문에 다른 세션이 이보다 오래 기다리면 덤프를 끊는다 (기본 200. 감시 주기와 끊는 데
#                     드는 시간을 더해도 앱이 보는 대기가 300ms 를 넘지 않게)
#
# 덤프는 일관 스냅샷이다. 덤프 계정에 RELOAD · FLUSH_TABLES 가 없으므로 MySQL Shell 은 LOCK INSTANCE FOR BACKUP(DDL 만 막음)과
# 덤프 대상 표의 LOCK TABLES READ 를 잠깐 걸고, 모든 스레드가 스냅샷을 잡으면 푼다. 그동안 그 표에 대한 쓰기가 기다리고,
# 쓰기 트랜잭션이 열려 있으면 잠금이 그 트랜잭션을 기다리는 동안 뒤의 쓰기도 함께 기다린다.
# 그래서 덤프 직전에 오래 도는 문장이 없는지 보고, 덤프하는 동안 별도 세션이 잠금 때문에 기다리는 세션을 지켜보다가
# LOCK_WAIT_MAX_MS 를 넘으면 덤프 세션을 끊어 실패시킨다(기다리던 쓰기는 바로 풀린다. 다음 기회에 다시 한다).
# 적재는 RDS 가 read_only=0 이고 local_infile=1 일 때 한다. 덤프 · 적재 모두 체크섬으로 검증한다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need NCP_HOST NCP_PORT DUMP_PASSWORD RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD
dump_user="${DUMP_USER:-dump_rds}"
NCP_USER=$dump_user # 이 스크립트의 NCP 조회는 모두 덤프 계정으로 한다
NCP_PASSWORD=$DUMP_PASSWORD
read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
dump_dir="${DUMP_DIR:-$WORK_DIR/dump-$(date -u +%Y%m%dT%H%M%S)}"
js_list=$(printf "'%s'," "${schemas[@]}")
js_list="[${js_list%,}]"
lock_wait_max="${LOCK_WAIT_MAX_MS:-200}"
(($# == 0)) || die "인자를 받지 않는다: $*"
ident_ok APP_SCHEMAS
runbook_lock
guard_rehearsal

[[ "$(rds_val 'SELECT @@global.read_only')" == 0 ]] || die "RDS 가 read_only 다. 적재는 read_only=0 일 때 한다"
[[ "$(rds_val 'SELECT @@global.local_infile')" == 1 ]] || die "RDS local_infile 이 꺼져 있다(파라미터 그룹)"
[[ "$(rds_val "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ($(printf "'%s'," "${schemas[@]}" | sed 's/,$//'))")" == 0 ]] ||
  die "RDS 의 옮길 DB 에 표가 있다. 빈 DB 에만 적재한다"
# 리허설 적재는 RDS 에 표식 DB 를 남긴다(50 clean-rds 는 이 표식이 있을 때만 지운다). 실제 적재는 표식이 남아 있으면 멈춘다
marker=$(rds_val "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$REHEARSAL_MARKER_DB'")
if is_rehearsal; then
  rds <<<"CREATE DATABASE IF NOT EXISTS \`$REHEARSAL_MARKER_DB\`"
else
  [[ "$marker" == 0 ]] || die "RDS 에 리허설 표식($REHEARSAL_MARKER_DB)이 남아 있다. 50-rehearsal-proxysql.sh clean-rds 를 먼저 한다"
fi

# 비밀번호는 표준 입력으로 넘긴다(--passwords-from-stdin)
shell() { # shell <계정> <호스트> <포트> <비밀번호> <JS>
  mysqlsh --js --uri="$1@$2:$3" --ssl-mode=REQUIRED --passwords-from-stdin --quiet-start=2 -e "$5" <<<"$4"
}

# ── 덤프 직전: 긴 문장 ──────────────────────────────────────
long=$(ncp_val "SELECT CONCAT(id, ' ', user, ' ', time, 's ', COALESCE(state, ''), ' ', COALESCE(SUBSTR(info, 1, 60), ''))
  FROM information_schema.processlist WHERE command NOT IN ('Sleep', 'Daemon', 'Binlog Dump', 'Binlog Dump GTID') AND id <> CONNECTION_ID()
   AND time >= ${LONG_STMT_SECONDS:-1}")
[[ -z "$long" ]] || die "NCP 에 오래 도는 문장이 있다. 끝난 뒤 다시 한다:"$'\n'"$long"
fault_point before_dump

# ── 덤프 시작 잠금 지켜보기 ─────────────────────────────────
# 잠금 때문에 기다리는 세션이 LOCK_WAIT_MAX_MS 넘게 이어지면 덤프 계정의 mysqlsh 세션을 끊는다. 감시도 덤프 계정으로 붙어서
# CONNECTION_ADMIN 없이 자기 계정의 세션을 끊는다(전역 읽기 잠금 · 표 비우기 대기는 덤프 계정에 권한이 생겼을 때를 대비해 함께 본다)
watch_lock() {
  local since=0 now ids
  trap sess_close_all EXIT
  sess_open watch "$NCP_HOST" "$NCP_PORT" "$NCP_USER" "$NCP_PASSWORD" REQUIRED || { log "잠금 감시 세션을 열지 못했다($SQ)"; exit 1; }
  : >"$dump_dir.ready"
  while [[ ! -e "$dump_dir.done" ]]; do
    # 본 프로세스가 강제로 죽으면 고아가 된 덤프 세션(표 잠금을 쥐고 있을 수 있다)을 끊고 끝낸다
    if ! kill -0 "$main_pid" 2>/dev/null; then
      sess_q watch 1000 "SELECT GROUP_CONCAT(id) FROM information_schema.processlist WHERE user = '$NCP_USER' AND id <> CONNECTION_ID()" || true
      for id in ${SQ//,/ }; do sess_q watch 1000 "KILL $id" || true; done
      exit 0
    fi
    if sess_q watch 1000 "SELECT COUNT(*) FROM information_schema.processlist WHERE state IN ('Waiting for table metadata lock', 'Waiting for global read lock', 'Waiting for table flush', 'Waiting for backup lock') AND id <> CONNECTION_ID()" && [[ "$SQ" =~ ^[0-9]+$ ]]; then
      now=$(ms)
      if ((SQ == 0)); then
        since=0
      elif ((since == 0)); then
        since=$now
      elif ((now - since > lock_wait_max)); then
        # 덤프 계정의 세션은 이 감시 세션과 mysqlsh 뿐이다
        sess_q watch 1000 "SELECT GROUP_CONCAT(id) FROM information_schema.processlist WHERE user = '$NCP_USER' AND id <> CONNECTION_ID()" || true
        ids=$SQ
        log "덤프 시작 잠금 때문에 다른 세션이 ${lock_wait_max} ms 넘게 기다린다. 덤프 세션($ids)을 끊는다"
        for id in ${ids//,/ }; do sess_q watch 1000 "KILL $id" || true; done
        : >"$dump_dir.killed"
        exit 0
      fi
    fi
    sleep 0.02
  done
}

# 아래 정리가 지우는 것은 이 실행이 채운 디렉터리뿐이어야 하므로, 이미 무언가 든 경로는 받지 않는다
[[ ! -e "$dump_dir" ]] || [[ -d "$dump_dir" && -z "$(ls -A "$dump_dir")" ]] || die "DUMP_DIR($dump_dir)이 비어 있지 않다. 없는 경로나 빈 디렉터리를 준다"
# 어떻게 끝나든(실패 포함) 운영 데이터 전체가 든 덤프를 지운다. KEEP_DUMP=1 이면 남긴다
cleanup_dump() {
  rm -f "$dump_dir.done" "$dump_dir.killed" "$dump_dir.ready"
  [[ "${KEEP_DUMP:-}" == 1 || ! -d "$dump_dir" ]] || { rm -rf "$dump_dir"; log "덤프 디렉터리를 지웠다(운영 데이터 전체가 들어 있다)"; }
  return "$1"
}
# shellcheck disable=SC2034 # lib.sh 의 끝 처리가 부른다
ON_EXIT=cleanup_dump

log "덤프 $js_list → $dump_dir"
rm -f "$dump_dir.done" "$dump_dir.killed" "$dump_dir.ready"
main_pid=$$
watch_lock &
watcher=$!
for _ in $(seq 100); do [[ ! -e "$dump_dir.ready" ]] || break; kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
[[ -e "$dump_dir.ready" ]] || { kill "$watcher" 2>/dev/null || true; die "잠금 감시를 시작하지 못해 덤프하지 않는다"; }
rm -f "$dump_dir.ready"
start=$(date +%s)
# 덤프가 끝나면 같은 세션에서 메타데이터(@.json)의 복제 시작점을 읽어 COORD 줄로 낸다.
# (접속 정보 없이 MySQL Shell 을 부르면 로컬 소켓에 접속하려 해서 따로 읽지 않는다)
# REPLICATION CLIENT 가 있어야 binlog 위치가 남는다. GTID 집합의 쉼표 · 줄바꿈은 JSON 으로 읽어 공백만 지운다.
dump_js="util.dumpSchemas($js_list, '$dump_dir', {consistent: true, threads: 4, checksum: true});
const m = JSON.parse(os.loadTextFile('$dump_dir/@.json'));
println('');
println('COORD file=' + (m.binlogFile || ''));
println('COORD pos=' + (m.binlogPosition || ''));
println('COORD gtid=' + String(m.gtidExecuted || '').replace(/\\s/g, ''));
println('COORD inconsistent=' + (m.gtidExecutedInconsistent === true));"
rc=0
dump_out=$(shell "$NCP_USER" "$NCP_HOST" "$NCP_PORT" "$NCP_PASSWORD" "$dump_js" | tee /dev/stderr) || rc=$?
: >"$dump_dir.done"
wait "$watcher" || true
if [[ -e "$dump_dir.killed" ]]; then
  die "덤프 시작 잠금이 쓰기를 ${lock_wait_max} ms 넘게 막아 덤프를 끊었다. 부하가 적을 때 다시 한다"
fi
rm -f "$dump_dir.done"
((rc == 0)) || die "덤프 실패"
log "덤프 끝 ($(($(date +%s) - start))초)"

# 비밀번호 안내 문구가 줄바꿈 없이 표준 출력에 먼저 찍히므로 줄 중간의 COORD 도 읽는다
coord() { sed -n "s/^.*COORD $1=//p" <<<"$dump_out" | tail -n1; }
[[ "$(coord inconsistent)" == false ]] || die "덤프의 GTID 집합을 믿을 수 없다(gtidExecutedInconsistent). 다시 덤프한다"
[[ -n "$(coord file)" && -n "$(coord pos)" ]] || die "덤프 메타데이터에 binlog 위치가 없다 (REPLICATION CLIENT 확인)"
coords_save "$(coord file)" "$(coord pos)" "$(coord gtid)"
log "복제 시작점 $(coord file):$(coord pos) (gtid_executed $(coord gtid)) 기록"

log "적재 → RDS"
start=$(date +%s)
shell "$RDS_USER" "$RDS_HOST" "$RDS_PORT" "$RDS_PASSWORD" \
  "util.loadDump('$dump_dir', {threads: 4, loadUsers: false, updateGtidSet: 'off', checksum: true, resetProgress: true})"
log "적재 끝 ($(($(date +%s) - start))초)"
