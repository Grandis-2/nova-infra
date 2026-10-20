#!/usr/bin/env bash
# RDS 에 NCP 와 같은 이름 · 비밀번호의 계정을 만든다 (이전 계획 1단계 5번).
# 같게 두어야 ProxySQL 이 한 계정으로 두 DB 에 붙고, 전환 때 앱 시크릿을 바꾸지 않는다.
#
#   RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD   RDS 마스터 계정
#   ACCOUNTS       "계정:단계 ..." (단계: CRUD · DDL · READ · MONITOR)
#   PW_<계정>      계정마다 비밀번호 (계정 이름을 대문자로. 운영에서는 Secrets Manager 에서 읽어 넣는다)
#   APP_SCHEMAS    권한을 줄 DB (기본: shop external_mock)
#
# 권한은 G1(10/19)에서 읽은 NCP 의 실제 권한과 같게 둔다(권한 축소는 이전과 섞지 않는다). 다만 RDS 마스터가 갖지 않아
# 남에게 줄 수 없는 것은 뺀다: DDL 의 BACKUP_ADMIN · FLUSH_TABLES · SHOW_ROUTINE, mysql.time_zone* 쓰기(RDS 8.0.36 부터 mysql
# 스키마는 직접 고칠 수 없다). 모두 Flyway 와 앱이 쓰지 않는다. RDS 가 read_only 면 마스터도 계정을 못 만들므로 read_only=0 일 때
# 돌린다. 여러 번 돌려도 된다(있으면 비밀번호와 권한만 맞춘다).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD ACCOUNTS
read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
(($# == 0)) || die "인자를 받지 않는다: $*"
ident_ok ACCOUNTS APP_SCHEMAS
runbook_lock

[[ "$(rds_val 'SELECT @@global.read_only')" == 0 ]] || die "RDS 가 read_only 다. read_only=0 일 때 돌린다"

grants_for() { # grants_for <계정> <단계>
  local u=$1 level=$2 s go=""
  [[ $level != DDL ]] || go=" WITH GRANT OPTION"
  case $level in
    DDL) echo "GRANT PROCESS, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT, CREATE USER ON *.* TO '$u'@'%'$go;"
         echo "GRANT XA_RECOVER_ADMIN ON *.* TO '$u'@'%'$go;" ;;
    CRUD | READ) echo "GRANT PROCESS, SHOW DATABASES, REPLICATION CLIENT ON *.* TO '$u'@'%';" ;;
    MONITOR) return 0 ;; # 접속만 한다(USAGE)
    *) die "모르는 단계: $level ($u)" ;;
  esac
  echo "GRANT SELECT ON mysql.* TO '$u'@'%'$go;"
  echo "GRANT SELECT, EXECUTE ON sys.* TO '$u'@'%'$go;"
  echo "GRANT SELECT ON performance_schema.* TO '$u'@'%'$go;"
  for s in "${schemas[@]}"; do
    case $level in
      DDL) echo "GRANT ALL PRIVILEGES ON \`$s\`.* TO '$u'@'%'$go;" ;;
      CRUD) echo "GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW, EVENT ON \`$s\`.* TO '$u'@'%';" ;;
      READ) echo "GRANT SELECT, LOCK TABLES, EXECUTE, SHOW VIEW ON \`$s\`.* TO '$u'@'%';" ;;
    esac
  done
}

sql=""
for entry in $ACCOUNTS; do
  u=${entry%%:*}
  level=${entry##*:}
  v="PW_${u^^}"
  [[ -n "${!v:-}" ]] || die "$v 가 비어 있습니다"
  [[ "${!v}" != *[\'\"\\]* ]] || die "$v 에 SQL 문자열에 넣을 수 없는 문자(' \" \\)가 있다"
  sql+="CREATE USER IF NOT EXISTS '$u'@'%' IDENTIFIED BY '${!v}';"$'\n'
  sql+="ALTER USER '$u'@'%' IDENTIFIED BY '${!v}';"$'\n'
  sql+="$(grants_for "$u" "$level")"$'\n'
done
log "RDS 계정 ${ACCOUNTS// /, }"
rds <<<"$sql"
rds <<<"SELECT user, host, plugin FROM mysql.user WHERE host = '%' ORDER BY user"
# 단계마다 한 계정의 권한을 보여 준다. G1 출력(NCP 의 SHOW GRANTS)과 대조한다
declare -A shown=()
for entry in $ACCOUNTS; do
  level=${entry##*:}
  [[ -z "${shown[$level]:-}" && $level != MONITOR ]] || continue
  shown[$level]=1
  log "권한 ($level): ${entry%%:*}"
  rds <<<"SHOW GRANTS FOR '${entry%%:*}'@'%'"
done
