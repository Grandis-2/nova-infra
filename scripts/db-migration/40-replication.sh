#!/usr/bin/env bash
# RDS 를 NCP 의 복제본으로 잇고, 상태를 보고, 멈춘다 (이전 계획 1단계 4 · 6 · 7번).
#
#   scripts/db-migration/40-replication.sh g2       관문 G2: 복제 연결만 시험하고 지운다 (덤프 전, RDS read_only=0 이어도 된다)
#   scripts/db-migration/40-replication.sh start    덤프 위치(coords_load)부터 위치 기반 복제를 시작한다
#   scripts/db-migration/40-replication.sh status   복제 스레드 · 지연 · 오류 · GTID
#   scripts/db-migration/40-replication.sh stop     복제를 멈춘다 (설정은 남는다)
#   scripts/db-migration/40-replication.sh resume   멈춘 복제를 멈춘 곳부터 다시 돌린다 (start 는 덤프 위치로 처음부터 건다)
#   scripts/db-migration/40-replication.sh compare  같은 시점의 NCP 와 RDS 를 표마다 체크섬으로 비교한다 (복제하는 동안 언제든)
#   scripts/db-migration/40-replication.sh reset    복제 설정을 지운다 (전환이 끝난 뒤)
#
#   RDS_* RDS_MODE COORDS_FILE|COORDS_SSM_PARAM (lib.sh)
#   NCP_*                     g2 가 NCP 의 현재 binlog 위치를 읽을 때 쓴다
#   SOURCE_HOST SOURCE_PORT   RDS 가 붙을 NCP 주소 (운영: Public 도메인)
#   REPL_PASSWORD             repl_rds 비밀번호
#
# 운영(rds)은 mysql.rds_* 프로시저를 쓴다. 복제 계정이 caching_sha2_password 라 SSL(마지막 인자 1)이 필수이고,
# 인증서는 검증하지 않는다. 로컬(native)은 같은 일을 CHANGE REPLICATION SOURCE TO 로 한다.
# start 전에 RDS 를 read_only=1 로 둔다(복제 스레드는 막히지 않고, 사람 · 앱의 실수 쓰기만 막힌다).
#
# g2 는 NCP 의 지금 위치에서 복제를 걸되, SQL 스레드는 그 위치에서 멈추게(UNTIL) 해서 RDS 에 아무것도 적용하지 않는다.
# IO 스레드가 NCP 에 붙어 binlog 를 받는지(Replica_IO_Running=Yes, IO 오류 없음)와 SQL 스레드가 시작 위치에서 멈춰 있는지
# (Exec_Source_Log_Pos) 보고 복제 설정을 지운다. 끝나고 두 DB 의 표 수가 시작 때와 같은지 본다.
# RDS 의 gtid_executed 는 비교하지 않는다(RDS 프로시저 · 하트비트가 스스로 남기는 기록으로 늘 수 있다).
#
# compare 는 쓰기를 막지 않는다. NCP gtid_executed 를 읽고(G1) RDS 가 그것까지 적용하기를 기다린 뒤 두 쪽 표를 모두 CHECKSUM 하고,
# NCP gtid_executed 를 다시 읽는다(G2). G1 = G2 면 그동안 쓰기가 없었으니 같은 시점의 비교다. 다르면 버리고 COMPARE_GAP_SECONDS
# (기본 2) 뒤 다시 한다(COMPARE_ATTEMPTS, 기본 30번). 사람 요청을 멈춰 달라고 알려 두면 조용한 틈이 잦다. 앱의 주기 작업도
# 쓰므로 재고 대조 시각(KST 04 · 05시)은 피한다. 다르면 다른 표를 보여 주고 1 로 끝낸다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD
mode="${RDS_MODE:-rds}"
cmd="${1:?g2 · start · status · stop · resume · reset · compare 중 하나}"
read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
(($# == 1)) || die "인자는 명령 하나다: $*"
ident_ok SOURCE_HOST APP_SCHEMAS
[[ $cmd == status || $cmd == compare ]] || runbook_lock "$cmd" # 읽기만 하는 명령은 잠그지 않는다
guard_rehearsal
[[ "${REPL_PASSWORD:-}" != *[\'\"\\]* ]] || die "REPL_PASSWORD 에 SQL 문자열에 넣을 수 없는 문자(' \" \\)가 있다"

status() {
  rds_ctl -E --column-names <<<"SHOW REPLICA STATUS" | grep -E '^ *(Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Source_Host|Relay_Source_Log_File|Exec_Source_Log_Pos|Until_Condition|Last_IO_Error|Last_SQL_Error|Retrieved_Gtid_Set|Executed_Gtid_Set|Source_SSL_Allowed):' || echo "(복제 설정 없음)"
}
field() { rds_ctl -E --column-names <<<"SHOW REPLICA STATUS" | sed -n "s/^ *$1: //p"; }

set_source() { # set_source <binlog 파일> <위치>
  if [[ $mode == rds ]]; then
    rds_ctl <<<"CALL mysql.rds_set_external_source('$SOURCE_HOST', $SOURCE_PORT, 'repl_rds', '$REPL_PASSWORD', '$1', $2, 1)"
  else
    rds_ctl <<<"CHANGE REPLICATION SOURCE TO SOURCE_HOST='$SOURCE_HOST', SOURCE_PORT=$SOURCE_PORT, SOURCE_USER='repl_rds',
  SOURCE_PASSWORD='$REPL_PASSWORD', SOURCE_LOG_FILE='$1', SOURCE_LOG_POS=$2, SOURCE_SSL=1"
  fi
}
reset_source() {
  if [[ $mode == rds ]]; then
    rds_ctl <<<"CALL mysql.rds_stop_replication" >/dev/null 2>&1 || true
    rds_ctl <<<"CALL mysql.rds_reset_external_source"
  else
    rds_ctl <<<"STOP REPLICA; RESET REPLICA ALL"
  fi
}
rds_tables() { rds_val "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ($(printf "'%s'," "${schemas[@]}" | sed 's/,$//'))"; }

case $cmd in
  g2)
    need NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD SOURCE_HOST SOURCE_PORT REPL_PASSWORD
    [[ "$(field Source_Host)" == "" ]] || die "RDS 에 이미 복제 설정이 있다($(field Source_Host)). 시험하지 않는다"
    read -r file pos _ <<<"$(ncp_val 'SHOW BINARY LOG STATUS')"
    [[ "$file" =~ ^[A-Za-z0-9._-]+$ && "$pos" =~ ^[0-9]+$ ]] || die "NCP binlog 위치를 읽지 못했다"
    before=$(rds_tables)
    cleanup() { reset_source >/dev/null || log "경고: 복제 설정을 지우지 못했다. reset 을 직접 돌린다"; }
    ON_EXIT=cleanup
    log "G2: $SOURCE_HOST:$SOURCE_PORT $file:$pos 에서 연결만 시험 ($mode)"
    set_source "$file" "$pos"
    if [[ $mode == rds ]]; then
      rds_ctl <<<"CALL mysql.rds_start_replication_until('$file', $pos)"
    else
      rds_ctl <<<"START REPLICA UNTIL SOURCE_LOG_FILE='$file', SOURCE_LOG_POS=$pos"
    fi
    io=""
    for _ in $(seq 30); do
      io=$(field Replica_IO_Running)
      [[ "$io" != Connecting ]] && break
      sleep 1
    done
    status
    err=$(field Last_IO_Error)
    exec_pos=$(field Exec_Source_Log_Pos)
    reset_source >/dev/null
    # shellcheck disable=SC2034 # lib.sh 의 끝날 때 처리가 읽는다
    ON_EXIT=""
    after=$(rds_tables)
    [[ "$before" == "$after" ]] || die "G2: RDS 의 표 수가 바뀌었다 ($before → $after)"
    [[ "$exec_pos" == "$pos" ]] || die "G2: SQL 스레드가 시작 위치($pos)를 지나 적용했다(Exec_Source_Log_Pos=$exec_pos)"
    [[ "$io" == Yes && -z "$err" ]] || die "G2 실패: IO 스레드 $io, 오류 ${err:-없음}"
    log "G2 통과: IO 스레드가 NCP 에 붙었고, RDS 는 그대로다. 복제 설정은 지웠다"
    ;;
  start)
    need SOURCE_HOST SOURCE_PORT REPL_PASSWORD
    coords_load
    # 리허설은 비어 있는 운영 RDS 로 하고 끝나면 비우므로 read_only=0 인 채로 둔다(파라미터 그룹 PR 을 오가지 않게)
    [[ "$(rds_val 'SELECT @@global.read_only')" == 1 ]] || is_rehearsal || die "RDS 를 먼저 read_only=1 로 둔다"
    log "복제 시작: $SOURCE_HOST:$SOURCE_PORT $DUMP_BINLOG_FILE:$DUMP_BINLOG_POS ($mode)"
    set_source "$DUMP_BINLOG_FILE" "$DUMP_BINLOG_POS"
    rds_ctl <<<"$(repl_start_sql)"
    sleep 2
    status
    ;;
  compare)
    need NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD
    coords_load
    in_list=$(printf "'%s'," "${schemas[@]}" | sed 's/,$//')
    sums() { # sums <ncp|rds>   "DB.표<TAB>체크섬" 줄들. 조회가 실패하면 1
      local tables
      tables=$("${1}_val" "SET SESSION group_concat_max_len = 1000000; SELECT GROUP_CONCAT(CONCAT('\`', table_schema, '\`.\`', table_name, '\`') ORDER BY table_schema, table_name) FROM information_schema.tables WHERE table_schema IN ($in_list) AND table_type='BASE TABLE'") || return 1
      [[ -n "$tables" && "$tables" != NULL ]] || return 0
      "${1}_val" "CHECKSUM TABLE $tables"
    }
    for attempt in $(seq "${COMPARE_ATTEMPTS:-30}"); do
      g1=$(ncp_val 'SELECT @@global.gtid_executed' | tr -d '\n ') || die "NCP gtid_executed 읽기 실패"
      caught=0
      for _ in $(seq 50); do
        [[ "$(rds_val "SELECT GTID_SUBSET(GTID_SUBTRACT('$g1', '$DUMP_GTID_EXECUTED'), @@global.gtid_executed)")" == 1 ]] && { caught=1; break; }
        sleep 0.2
      done
      ((caught)) || { log "$attempt번째: RDS 가 10초 안에 따라잡지 못했다(복제 상태 확인). 다시"; sleep "${COMPARE_GAP_SECONDS:-2}"; continue; }
      want=$(sums ncp) || die "NCP 체크섬 실패"
      got=$(sums rds) || die "RDS 체크섬 실패"
      g2=$(ncp_val 'SELECT @@global.gtid_executed' | tr -d '\n ') || die "NCP gtid_executed 읽기 실패"
      if [[ "$g1" != "$g2" ]]; then
        log "$attempt번째: 비교하는 동안 NCP 에 쓰기가 있었다. ${COMPARE_GAP_SECONDS:-2}초 뒤 다시"
        sleep "${COMPARE_GAP_SECONDS:-2}"
        continue
      fi
      diff_tables=$(comm -3 <(sort <<<"$want") <(sort <<<"$got") | sed 's/^\t//' | cut -f1 | sort -u)
      if [[ -z "$diff_tables" ]]; then
        log "같다: 표 $(grep -c . <<<"$want")개, NCP 시점 $g1 ($attempt번째)"
        exit 0
      fi
      log "다르다(NCP 시점 $g1). 체크섬이 다른 표:"
      printf '  %s\n' $diff_tables >&2
      exit 1
    done
    die "${COMPARE_ATTEMPTS:-30}번 모두 비교하는 동안 쓰기가 있었다. 요청이 적을 때 다시 한다"
    ;;
  status) status ;;
  stop)
    rds_ctl <<<"$(repl_stop_sql)"
    status
    ;;
  resume)
    [[ "$(field Source_Host)" != "" ]] || die "복제 설정이 없다. start 로 건다"
    rds_ctl <<<"$(repl_start_sql)"
    sleep 2
    status
    ;;
  reset)
    reset_source
    status
    ;;
  *) die "모르는 명령: $cmd" ;;
esac
