#!/usr/bin/env bash
# tools 컨테이너 안에서 db-migration 스크립트를 로컬 접속 정보로 돌린다.
#
#   scripts/db-migration/local/tools.sh <스크립트 파일 이름> [인자...]
#   예) scripts/db-migration/local/tools.sh 40-replication.sh status
#
# ncp 는 nova_admin, rds 는 nova_master(복제 제어 · read_only 는 root 가 RDS 프로시저 · 파라미터 그룹을 대신한다).
# 비밀번호는 컨테이너가 읽은 work/local.env 에서 꺼낸다. 쓰기 대상 기록은 work/writer, 복제 시작점은 work/dump-coords.env 다.
# 아래 PASS 의 변수는 호스트에서 준 값을 그대로 넘긴다(시험마다 예산 · 실패 주입을 바꿀 때).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
PASS="DUMP_DIR PROXYSQL_FROM PROXYSQL_TO PROXYSQL_NODES PROXYSQL_HOSTGROUP BUDGET_MS BUDGET_MARGIN_MS ATTEMPTS RETRY_GAP_SECONDS QUIET_WAIT_MS DRAIN_TIMEOUT_MS
  WAIT_LIMIT_MS CYCLES GAP_SECONDS FAULT_POINT LOCK_WAIT_MAX_MS LONG_STMT_SECONDS KEEP_COPY KEEP_DUMP SETTLE_TIMEOUT_MS
  MONITOR_WAIT_SECONDS WRITER_FILE COORDS_FILE WRITER_SSM_PARAM NCP_HOST RDS_HOST PROXYSQL_NODES_CMD REHEARSAL_NCP_HOST REHEARSAL_RDS_HOST REHEARSAL_USER REHEARSAL_PASSWORD"
args=()
for v in $PASS; do [[ -z "${!v:-}" ]] || args+=(-e "$v=${!v}"); done
docker compose exec -T \
  -e NCP_HOST=ncp -e NCP_PORT=3306 -e NCP_USER=nova_admin \
  -e RDS_HOST=rds -e RDS_PORT=3306 -e RDS_USER=nova_master -e RDS_MODE=native -e RDS_CONTROL_USER=root \
  -e SOURCE_HOST=ncp -e SOURCE_PORT=3306 \
  -e PROXYSQL_NODES="proxysql1:6032 proxysql2:6032" -e PROXYSQL_USER=radmin \
  -e ACCOUNTS="batch:CRUD catalog:CRUD member:CRUD mock:CRUD order:CRUD payment:CRUD preorder:CRUD worker:CRUD nova_migrator:DDL nova_exporter:READ proxysql_mon:MONITOR" \
  -e WRITER_FILE=/work/writer -e COORDS_FILE=/work/dump-coords.env -e FAULT_DIR=/work/fault \
  ${args[@]+"${args[@]}"} \
  tools bash -c '
    export NCP_PASSWORD="$PW_NOVA_ADMIN" RDS_PASSWORD="$PW_NOVA_MASTER" RDS_CONTROL_PASSWORD="$MYSQL_ROOT_PASSWORD"
    export REPL_PASSWORD="$PW_REPL_RDS" PROXYSQL_MON_PASSWORD="$PW_PROXYSQL_MON" PROXYSQL_PASSWORD="$PW_PROXYSQL_ADMIN"
    export NCP_MIGRATOR_PASSWORD="$PW_NOVA_MIGRATOR" DUMP_PASSWORD="$PW_DUMP_RDS"
    exec "/scripts/$0" "$@"' "$@"
