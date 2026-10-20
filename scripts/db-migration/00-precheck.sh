#!/usr/bin/env bash
# NCP(소스)가 RDS 로 복제할 수 있는 상태인지 읽기만 해서 확인한다 (이전 계획 0단계, 관문 G1).
# SELECT 와 SHOW 만 쓴다. 쓰기 문장은 없다.
#
#   NCP_HOST=<호스트> NCP_PORT=<포트> NCP_USER=nova_admin NCP_PASSWORD=<비밀번호> scripts/db-migration/00-precheck.sh
#
#   APP_SCHEMAS        옮길 DB 목록 (기본: shop external_mock)
#   GRANT_CHECK_USERS  권한을 함께 볼 계정 (기본: nova_migrator nova_exporter 와 앱 계정 전부, 호스트는 %)
#
# 마지막 "G1 판정" 의 필수 항목이 모두 OK 면 종료 코드 0, 하나라도 아니면 2 다.
# 비밀번호 해시가 든 문장(CREATE USER 등)은 binlog 집계에서 문장 종류만 남기고 지운다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD

read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
read -r -a grant_users <<<"${GRANT_CHECK_USERS:-nova_migrator nova_exporter batch catalog member mock order payment preorder worker}"
ident_ok APP_SCHEMAS GRANT_CHECK_USERS # SQL 에 그대로 넣는 값이다
in_list=$(printf "'%s'," "${schemas[@]}")
in_list=${in_list%,}

section() { printf '\n## %s\n' "$1"; }
results=()
fail=0
verdict() { # verdict <필수|참고> <OK|WARN|FAIL> <항목> <설명>
  results+=("$(printf '[%s] %s · %s: %s' "$2" "$1" "$3" "$4")")
  if [[ "$1" == 필수 && "$2" != OK ]]; then fail=1; fi
}

# ── 서버 변수 ───────────────────────────────────────────────
section "서버 변수"
declare -A var
while IFS=$'\t' read -r k v; do var[$k]=$v; printf '%-34s %s\n' "$k" "$v"; done < <(ncp <<SQL
SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables
 WHERE VARIABLE_NAME IN ('version','version_comment','server_id','server_uuid','log_bin','binlog_format','binlog_row_image',
   'binlog_checksum','binlog_expire_logs_seconds','binlog_transaction_compression','gtid_mode','enforce_gtid_consistency',
   'log_replica_updates','lower_case_table_names','character_set_server','collation_server','time_zone','system_time_zone',
   'sql_mode','explicit_defaults_for_timestamp','sql_require_primary_key','transaction_isolation','max_connections',
   'wait_timeout','innodb_lock_wait_timeout','lock_wait_timeout','require_secure_transport','authentication_policy',
   'local_infile','event_scheduler','max_allowed_packet','tls_version')
 ORDER BY VARIABLE_NAME;
SQL
)

[[ "${var[log_bin]:-}" == ON ]] && verdict 필수 OK "binlog 켜짐(log_bin)" "ON" || verdict 필수 FAIL "binlog 켜짐(log_bin)" "${var[log_bin]:-?}"
[[ "${var[binlog_format]:-}" == ROW ]] && verdict 필수 OK "binlog_format" "ROW" || verdict 필수 FAIL "binlog_format" "${var[binlog_format]:-?}"
[[ "${var[gtid_mode]:-}" == ON ]] && verdict 필수 OK "gtid_mode" "ON (따라잡음 판정에 씀)" || verdict 필수 FAIL "gtid_mode" "${var[gtid_mode]:-?}"
if (( ${var[binlog_expire_logs_seconds]:-0} >= 259200 )); then
  verdict 참고 OK "binlog 보존(3일 이상)" "${var[binlog_expire_logs_seconds]}초"
else
  verdict 참고 WARN "binlog 보존(3일 이상)" "${var[binlog_expire_logs_seconds]:-?}초 — DB Config 로 늘린다"
fi
[[ "${var[binlog_row_image]:-}" == FULL ]] && verdict 참고 OK "binlog_row_image" "FULL" || verdict 참고 WARN "binlog_row_image" "${var[binlog_row_image]:-?} — DMS 대안을 쓸 때만 FULL 필요"
[[ "${var[binlog_transaction_compression]:-OFF}" == OFF ]] && verdict 참고 OK "binlog 트랜잭션 압축" "OFF" || verdict 참고 WARN "binlog 트랜잭션 압축" "ON — DMS 대안은 지원하지 않음"

# ── 권한 ────────────────────────────────────────────────────
section "권한: $NCP_USER (현재 계정)"
my_grants=$(ncp <<<"SHOW GRANTS")
printf '%s\n' "$my_grants"
global_lines=$(grep -F ' ON *.* TO ' <<<"$my_grants" || true)
has_global() { grep -E "(^|[ ,])$1([ ,]|$)" <<<"$global_lines" | grep -q .; }
has_global_go() { grep -E "(^|[ ,])$1([ ,]|$)" <<<"$global_lines" | grep -F 'WITH GRANT OPTION' | grep -q .; }

has_global 'REPLICATION SLAVE' && verdict 필수 OK "REPLICATION SLAVE(전역)" "있음" || verdict 필수 FAIL "REPLICATION SLAVE(전역)" "없음 — RDS 가 binlog 를 받을 수 없다"
has_global 'REPLICATION CLIENT' && verdict 필수 OK "REPLICATION CLIENT(전역)" "있음" || verdict 필수 FAIL "REPLICATION CLIENT(전역)" "없음 — binlog 위치를 읽을 수 없다"
if has_global_go 'CREATE USER' && has_global_go 'REPLICATION SLAVE' && has_global_go 'REPLICATION CLIENT'; then
  verdict 참고 OK "복제 계정을 SQL 로 만들 권한" "CREATE USER · REPLICATION SLAVE/CLIENT WITH GRANT OPTION"
else
  verdict 참고 WARN "복제 계정을 SQL 로 만들 권한" "GRANT OPTION 없음 — 복제 계정은 별도 ncloud_mysql_users(DDL) 리소스로 만든다"
fi
if has_global 'BACKUP_ADMIN'; then
  verdict 참고 OK "일관 덤프(BACKUP_ADMIN)" "있음 — 덤프 중 DDL 만 막는다"
else
  verdict 참고 WARN "일관 덤프(BACKUP_ADMIN)" "없음 — MySQL Shell 이 추가 일관성 검사를 한다"
fi
# 덤프는 이 계정이 아니라 10-ncp-users.sh 가 만드는 dump_rds(RELOAD · FLUSH_TABLES 없음, LOCK TABLES 방식)로 한다.
# 그래서 여기서는 dump_rds 를 만들 수 있는지(BACKUP_ADMIN · LOCK TABLES 를 줄 수 있는지)를 본다
if has_global_go 'BACKUP_ADMIN'; then
  verdict 참고 OK "덤프 계정(dump_rds)을 만들 권한" "BACKUP_ADMIN WITH GRANT OPTION"
else
  verdict 참고 WARN "덤프 계정(dump_rds)을 만들 권한" "BACKUP_ADMIN 을 줄 수 없다 — 덤프 방식을 다시 본다"
fi
for s in "${schemas[@]}"; do
  if grep -E "ON \`$s\`\.\* TO " <<<"$my_grants" | grep -Eq 'ALL PRIVILEGES|LOCK TABLES'; then
    verdict 참고 OK "덤프 권한($s)" "ALL 또는 LOCK TABLES"
  else
    verdict 참고 WARN "덤프 권한($s)" "ALL · LOCK TABLES 가 보이지 않는다"
  fi
done

for u in "${grant_users[@]}"; do
  section "권한: $u@%"
  ncp <<<"SHOW GRANTS FOR '$u'@'%'" 2>&1 || true
done

# ── binlog ──────────────────────────────────────────────────
section "binlog 파일"
if logs=$(ncp <<<"SHOW BINARY LOGS" 2>&1); then
  printf '%s\n' "$logs" | awk -F'\t' '{n++; s+=$2; last=$1; if (n==1) first=$1} END {printf "파일 %d개, 합계 %.1f MiB, 처음 %s, 마지막 %s\n", n, s/1048576, first, last}'
  verdict 필수 OK "binlog 목록 읽기" "SHOW BINARY LOGS 성공"
  last_log=$(printf '%s\n' "$logs" | tail -n1 | cut -f1)
else
  printf '%s\n' "$logs"
  verdict 필수 FAIL "binlog 목록 읽기" "SHOW BINARY LOGS 실패"
  last_log=""
fi
ncp <<<"SHOW BINARY LOG STATUS" | awk -F'\t' '{printf "현재 위치 %s:%s\n실행된 GTID %s\n", $1, $2, $5}' || true

if [[ -n "$last_log" ]]; then
  section "binlog 이벤트 집계 (마지막 파일 $last_log, 최대 5000개)"
  # 앱이 아닌 쓰기(NCP 관리 기능 등)가 있는지 본다. 문장 원문은 남기지 않는다.
  ncp <<<"SHOW BINLOG EVENTS IN '$last_log' LIMIT 5000" | awk -F'\t' '
    { type[$3]++; sid[$4]++ }
    $3 == "Table_map" { if (match($6, /\(([^.)]+)\./, m)) db[m[1]]++ }
    $3 == "Query" && $6 != "BEGIN" {
      info = $6; d = "(기본 DB 없음)"
      if (match(info, /^use `([^`]+)`; /, m)) { d = m[1]; info = substr(info, RLENGTH + 1) }
      # 앞쪽 주석 · 공백을 걷어낸다. --batch 출력에서 줄바꿈은 글자 그대로 \n 이다
      while (1) {
        if (substr(info, 1, 2) == "--") { p = index(info, "\\n"); info = (p ? substr(info, p + 2) : "") }
        else if (substr(info, 1, 2) == "/*") { p = index(info, "*/"); info = (p ? substr(info, p + 2) : "") }
        else if (substr(info, 1, 2) == "\\n") { info = substr(info, 3) }
        else if (info ~ /^[ \t]/) { sub(/^[ \t]+/, "", info) }
        else break
      }
      split(info, w, /[ (]/)
      kind = (w[1] ~ /^[A-Za-z]+$/) ? toupper(w[1]) " " toupper(w[2]) : "(기타)"
      q[d " / " kind]++
    }
    END {
      print "[이벤트 종류]";              for (k in type) printf "  %-24s %d\n", k, type[k]
      print "[server_id]";                for (k in sid)  printf "  %-24s %d\n", k, sid[k]
      print "[행 변경이 있었던 DB]";      for (k in db)   printf "  %-24s %d\n", k, db[k]
      print "[문장(Query) DB / 종류]";    for (k in q)    printf "  %-40s %d\n", k, q[k]
    }' || verdict 참고 WARN "binlog 이벤트 읽기" "SHOW BINLOG EVENTS 실패"
fi

# ── DB · 표 ─────────────────────────────────────────────────
section "DB 목록 (시스템 DB 제외)"
ncp <<<"SELECT schema_name, default_character_set_name, default_collation_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY 1"

section "옮길 DB 크기"
ncp <<SQL
SELECT table_schema, COUNT(*) AS tables, SUM(table_rows) AS approx_rows,
       ROUND(SUM(data_length + index_length) / 1048576, 2) AS mib
  FROM information_schema.tables
 WHERE table_schema IN ($in_list) AND table_type = 'BASE TABLE'
 GROUP BY table_schema ORDER BY 1;
SQL

no_pk=$(ncp <<SQL
SELECT CONCAT(t.table_schema, '.', t.table_name) FROM information_schema.tables t
  LEFT JOIN information_schema.table_constraints c
    ON c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY'
 WHERE t.table_schema IN ($in_list) AND t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL;
SQL
)
[[ -z "$no_pk" ]] && verdict 참고 OK "PK 없는 표" "없음" || verdict 참고 WARN "PK 없는 표" "$(tr '\n' ' ' <<<"$no_pk")"

non_innodb=$(ncp <<<"SELECT CONCAT(table_schema, '.', table_name, '(', engine, ')') FROM information_schema.tables
                     WHERE table_schema IN ($in_list) AND table_type = 'BASE TABLE' AND engine <> 'InnoDB'")
[[ -z "$non_innodb" ]] && verdict 참고 OK "InnoDB 가 아닌 표" "없음" || verdict 참고 WARN "InnoDB 가 아닌 표" "$(tr '\n' ' ' <<<"$non_innodb")"

objects=$(ncp <<SQL
SELECT CONCAT('트리거 ', (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema IN ($in_list)),
              ', 루틴 ',  (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema IN ($in_list)),
              ', 이벤트 ', (SELECT COUNT(*) FROM information_schema.events WHERE event_schema IN ($in_list)),
              ', 뷰 ',    (SELECT COUNT(*) FROM information_schema.views WHERE table_schema IN ($in_list)));
SQL
)
verdict 참고 OK "트리거 · 루틴 · 이벤트 · 뷰" "$objects"

# ── 계정 · 세션 · 시계 ──────────────────────────────────────
section "계정 (mysql.user)"
ncp <<<"SELECT user, host, plugin, account_locked FROM mysql.user ORDER BY user, host"

section "보이는 세션"
ncp <<SQL
SELECT CONCAT('processlist ', (SELECT COUNT(*) FROM information_schema.processlist),
              ', performance_schema.threads(FOREGROUND) ', (SELECT COUNT(*) FROM performance_schema.threads WHERE type = 'FOREGROUND'));
SQL

section "시계"
db_now=$(ncp <<<"SELECT DATE_FORMAT(UTC_TIMESTAMP(6), '%Y-%m-%d %H:%i:%s.%f')")
local_now=$(date -u '+%Y-%m-%d %H:%M:%S.%6N')
skew_ms=$(( ( $(date -u -d "$db_now" +%s%6N) - $(date -u -d "$local_now" +%s%6N) ) / 1000 ))
printf 'DB %s, 이 서버 %s, 차이 약 %d ms (왕복 시간 포함)\n' "$db_now" "$local_now" "$skew_ms"

# ── 판정 ────────────────────────────────────────────────────
section "G1 판정"
printf '%s\n' "${results[@]}"
if (( fail )); then
  printf '\n결과: 필수 항목 중 OK 가 아닌 것이 있다. 복제로 진행하지 않고 다시 정한다.\n'
  exit 2
fi
printf '\n결과: 필수 항목이 모두 OK 다.\n'
