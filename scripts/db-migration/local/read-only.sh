#!/usr/bin/env bash
# 로컬 rds 의 read_only 를 바꾼다. 운영에서는 rds 스택의 파라미터 그룹(변수)을 Atlantis 로 바꾸는 일을 대신한다.
#
#   scripts/db-migration/local/read-only.sh on|off
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
case "${1:?on 또는 off}" in on) v=1 ;; off) v=0 ;; *) echo "on 또는 off" >&2; exit 1 ;; esac
docker compose exec -T tools bash -c '
  mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=\"%s\"\n" "$MYSQL_ROOT_PASSWORD") \
    --host=rds --ssl-mode=REQUIRED --batch --skip-column-names \
    -e "SET GLOBAL read_only = $0; SELECT CONCAT(\"rds read_only=\", @@global.read_only)"' "$v"
