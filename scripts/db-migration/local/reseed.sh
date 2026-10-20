#!/usr/bin/env bash
# 시험 환경을 "NCP 가 쓰기 대상이고 RDS 가 복제로 따라오는" 상태로 되돌린다(전환 · 되돌리기를 다시 시험하려고).
#
#   scripts/db-migration/local/reseed.sh          LOAD=0 이면 RDS 를 비우기만 하고 덤프 · 복제는 하지 않는다
#
# ProxySQL 두 대를 ncp ONLINE · rds 빠짐으로, 쓰기 대상 기록을 ncp 로 두고, RDS 복제 설정과 두 DB 를 지운 뒤 30 · 40 을 다시 한다.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
root() { # root <ncp|rds>  (SQL 은 표준 입력)
  docker compose exec -T tools bash -c '
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=\"%s\"\n" "$MYSQL_ROOT_PASSWORD") \
      --host="$0" --ssl-mode=REQUIRED --batch --skip-column-names' "$1"
}
docker compose exec -T tools bash -c '
  for n in proxysql1 proxysql2; do
    mysql --defaults-extra-file=<(printf "[client]\nuser=radmin\npassword=\"%s\"\n" "$PW_PROXYSQL_ADMIN") --host=$n --port=6032 --ssl-mode=DISABLED -e "
      UPDATE mysql_servers SET status=\"ONLINE\" WHERE hostgroup_id=10 AND hostname=\"ncp\"; UPDATE mysql_servers SET status=\"OFFLINE_HARD\" WHERE hostgroup_id=10 AND hostname=\"rds\";
      LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
  done'
echo ncp >work/writer
# 시험 도중 손으로 넣은 쓰기가 있어도 대조(카운터 = 행 수)가 이번 실행만 보도록 맞춘다
root ncp <<<"UPDATE shop.g3_probe_counter SET value = (SELECT COUNT(*) FROM shop.g3_probe_write) WHERE id = 1"
root rds <<'SQL'
STOP REPLICA; RESET REPLICA ALL;
SET GLOBAL read_only = 0;
DROP DATABASE IF EXISTS shop; DROP DATABASE IF EXISTS external_mock;
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE external_mock CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SQL
[[ "${LOAD:-1}" == 1 ]] || exit 0
./tools.sh 30-dump-load.sh >/dev/null 2>&1
./read-only.sh on >/dev/null
./tools.sh 40-replication.sh start | grep -E 'Running:' | tr -s ' ' | tr '\n' ' '
echo
