#!/usr/bin/env bash
# 리허설(이전 계획 3단계)을 운영 ProxySQL 의 별도 그룹에서, 리허설 NCP(운영 백업으로 만든 것)와 아직 비어 있는 운영 RDS 로 돌린다.
# 리허설이 끝나면 운영 RDS 를 비우고 실제 덤프부터 한다(결정 ⑩ B, 10/20).
#
#   scripts/db-migration/50-rehearsal-proxysql.sh setup      리허설 그룹에 리허설 NCP(ONLINE) · 운영 RDS(빠짐)와 시험 계정을 런타임에 넣는다
#   scripts/db-migration/50-rehearsal-proxysql.sh teardown   넣은 것을 모두 뺀다
#   scripts/db-migration/50-rehearsal-proxysql.sh clean-rds  리허설이 운영 RDS 에 남긴 것(복제 설정 · 두 DB · 시험 계정 · 표식)을 지운다.
#                                                            30 이 리허설 적재 때 남긴 표식 DB 가 있어야 지운다
#
#   PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD (lib.sh)   RDS_* RDS_MODE (clean-rds)
#   PROXYSQL_HOSTGROUP             리허설 그룹 (운영 그룹 PROXYSQL_PROD_HOSTGROUP, 기본 10 · 그 감시 그룹 11 과 겹치면 안 된다)
#   REHEARSAL_NCP_HOST · REHEARSAL_RDS_HOST   리허설 NCP 주소 · 운영 RDS 주소 (포트 3306)
#   REHEARSAL_USER · REHEARSAL_PASSWORD       시험 프로브가 붙을 계정. 두 DB 에도 같은 이름 · 비밀번호로 만들어 둔다
#   APP_SCHEMAS                    clean-rds 가 비울 DB (기본: shop external_mock)
#
# 런타임에만 넣고 디스크에는 저장하지 않는다. ProxySQL 태스크가 다시 뜨면 사라지고, 운영 설정(그룹 10 · 11 · 앱 계정)은 건드리지 않는다.
# 리허설 동안 30 · 40 · 45 · 60 · 70 은 PROXYSQL_HOSTGROUP · PROXYSQL_FROM · PROXYSQL_TO 를 리허설 값으로 주고, 쓰기 대상 ·
# 복제 시작점 기록은 파일(WRITER_FILE · COORDS_FILE)로 돌린다(lib.sh guard_rehearsal 가 운영 SSM 을 막는다).
# 운영 RDS 는 운영 그룹에서 아직 쓰기 대상이 아닐 때(모든 노드에서 빠져 있을 때)만 리허설에 쓴다. 리허설 NCP 는 운영 그룹에 없어야 한다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD PROXYSQL_HOSTGROUP REHEARSAL_NCP_HOST REHEARSAL_RDS_HOST REHEARSAL_USER
cmd="${1:?setup · teardown · clean-rds}"
(($# == 1)) || die "인자는 setup · teardown · clean-rds 하나다: $*"
hg=$(px_hg)
prod_hg="${PROXYSQL_PROD_HOSTGROUP:-10}"
[[ "$hg" =~ ^[0-9]+$ && "$hg" != "$prod_hg" && "$hg" != $((prod_hg + 1)) && $((hg + 1)) != "$prod_hg" ]] ||
  die "리허설 그룹($hg)과 그 감시 그룹($((hg + 1)))은 운영 그룹($prod_hg) · 운영 감시 그룹($((prod_hg + 1)))과 겹치면 안 된다"
for v in REHEARSAL_NCP_HOST REHEARSAL_RDS_HOST REHEARSAL_USER; do
  [[ "${!v}" =~ ^[A-Za-z0-9._-]+$ ]] || die "$v 에 쓸 수 없는 문자가 있다"
done
runbook_lock "$cmd"
px_open

# 리허설 NCP 가 운영 그룹에 있으면, 또는 운영 RDS 가 운영 그룹에서 쓰기 대상이면 멈춘다. 운영 앱 계정도 쓰지 않는다
for i in "${!PX[@]}"; do
  sess_must "${PX[$i]}" "SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id IN ($prod_hg, $((prod_hg + 1))) AND hostname='$REHEARSAL_NCP_HOST'"
  [[ "$SQ" == 0 ]] || die "${PX_NODE[$i]}: 리허설 NCP 주소가 운영 그룹($prod_hg)에 있다(운영 NCP 로 리허설하지 않는다)"
  sess_must "${PX[$i]}" "SELECT COUNT(*) FROM runtime_mysql_servers WHERE hostgroup_id=$prod_hg AND hostname='$REHEARSAL_RDS_HOST'"
  [[ "$SQ" == 0 ]] || die "${PX_NODE[$i]}: $REHEARSAL_RDS_HOST 가 운영 그룹($prod_hg)에 들어가 있다. 이미 운영에 쓰이는 RDS 로는 리허설하지 않는다"
  sess_must "${PX[$i]}" "SELECT COUNT(*) FROM mysql_users WHERE username='$REHEARSAL_USER' AND default_hostgroup<>$hg"
  [[ "$SQ" == 0 ]] || die "${PX_NODE[$i]}: $REHEARSAL_USER 는 다른 그룹을 쓰는 계정이다(운영 앱 계정을 쓰지 않는다)"
done

# 리허설 그룹 · 그 감시 그룹에 리허설 서버가 아닌 것이 있으면 멈춘다(다른 용도로 쓰는 그룹을 비우지 않게)
for i in "${!PX[@]}"; do
  sess_must "${PX[$i]}" "SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id IN ($hg, $((hg + 1))) AND hostname NOT IN ('$REHEARSAL_NCP_HOST', '$REHEARSAL_RDS_HOST')"
  [[ "$SQ" == 0 ]] || die "${PX_NODE[$i]}: 그룹 $hg · $((hg + 1)) 에 리허설이 아닌 서버가 있다. 다른 그룹 번호를 쓴다"
done

case $cmd in
  setup)
    need REHEARSAL_PASSWORD
    [[ "$REHEARSAL_PASSWORD" != *[\'\"\\]* ]] || die "REHEARSAL_PASSWORD 에 SQL 문자열에 넣을 수 없는 문자가 있다"
    # 리허설 그룹(hg)과 그 감시 전용 그룹(hg + 1, lib.sh px_reachable)을 함께 넣는다
    sql="DELETE FROM mysql_servers WHERE hostgroup_id IN ($hg, $((hg + 1)));
INSERT INTO mysql_servers (hostgroup_id, hostname, port, status, use_ssl, max_connections, comment) VALUES
  ($hg, '$REHEARSAL_NCP_HOST', 3306, 'ONLINE', 1, 100, 'rehearsal ncp'),
  ($hg, '$REHEARSAL_RDS_HOST', 3306, 'OFFLINE_HARD', 1, 100, 'rehearsal rds'),
  ($((hg + 1)), '$REHEARSAL_NCP_HOST', 3306, 'ONLINE', 1, 1, 'rehearsal ncp monitor only'),
  ($((hg + 1)), '$REHEARSAL_RDS_HOST', 3306, 'ONLINE', 1, 1, 'rehearsal rds monitor only');
DELETE FROM mysql_users WHERE username='$REHEARSAL_USER';
INSERT INTO mysql_users (username, password, default_hostgroup, active) VALUES ('$REHEARSAL_USER', '$REHEARSAL_PASSWORD', $hg, 1);
LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME"
    ;;
  teardown)
    sql="DELETE FROM mysql_servers WHERE hostgroup_id IN ($hg, $((hg + 1)));
DELETE FROM mysql_users WHERE username='$REHEARSAL_USER';
LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL USERS TO RUNTIME"
    ;;
  clean-rds)
    need RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD
    [[ "$RDS_HOST" == "$REHEARSAL_RDS_HOST" ]] || die "RDS_HOST($RDS_HOST)가 리허설에 쓴 RDS($REHEARSAL_RDS_HOST)와 다르다"
    ident_ok APP_SCHEMAS
    read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
    # 실제 이전이 이미 시작됐다면(운영 NCP 를 복제 중이거나 read_only=1) 지우지 않는다
    src=$(rds_ctl -E --column-names <<<"SHOW REPLICA STATUS" | sed -n 's/^ *Source_Host: //p')
    [[ -z "$src" || "$src" == "$REHEARSAL_NCP_HOST" ]] || die "RDS 가 리허설 NCP 가 아닌 $src 를 복제하고 있다. 실제 이전이 시작된 RDS 는 비우지 않는다"
    [[ "$(rds_val 'SELECT @@global.read_only')" == 0 ]] || die "RDS 가 read_only=1 이다. 실제 이전 단계로 보고 비우지 않는다"
    # 리허설 적재의 표식이 있어야 지운다(실제 덤프를 적재한 뒤 복제를 걸기 전에도 위 두 조건은 맞으므로 그것만으로는 모자란다)
    [[ "$(rds_val "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$REHEARSAL_MARKER_DB'")" == 1 ]] ||
      die "RDS 에 리허설 표식($REHEARSAL_MARKER_DB)이 없다. 리허설이 적재한 RDS 가 아닐 수 있어 지우지 않는다"
    log "운영 RDS 에서 리허설 흔적을 지운다: 복제 설정, ${schemas[*]}, $REHEARSAL_USER"
    if [[ "${RDS_MODE:-rds}" == native ]]; then
      rds_ctl <<<"STOP REPLICA; RESET REPLICA ALL"
    else
      rds_ctl <<<"CALL mysql.rds_stop_replication" >/dev/null 2>&1 || true
      rds_ctl <<<"CALL mysql.rds_reset_external_source"
    fi
    sql="DROP USER IF EXISTS '$REHEARSAL_USER'@'%'; DROP DATABASE \`$REHEARSAL_MARKER_DB\`;"
    for d in "${schemas[@]}"; do
      sql+="DROP DATABASE IF EXISTS \`$d\`; CREATE DATABASE \`$d\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
    done
    rds <<<"$sql"
    log "clean-rds 끝. 표 수: $(rds_val "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ($(printf "'%s'," "${schemas[@]}" | sed 's/,$//'))")"
    exit 0
    ;;
  *) die "setup · teardown · clean-rds" ;;
esac
px_all_q 5000 "$sql" || {
  # 오류 문구에 비밀번호가 든 INSERT 가 섞일 수 있어 결과 코드만 남긴다
  for i in "${!PX[@]}"; do ((PX_RC[i] == 0)) || log "${PX_NODE[$i]}: 실패 (코드 ${PX_RC[i]})"; done
  die "일부 노드에 싣지 못했다. 다시 돌린다(여러 번 돌려도 같다)"
}
px_state "$REHEARSAL_NCP_HOST" || true
log "$cmd 끝. 그룹 $hg 의 $REHEARSAL_NCP_HOST: $(px_state_text)"
