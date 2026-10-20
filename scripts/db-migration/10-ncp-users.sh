#!/usr/bin/env bash
# NCP 에 이전 기간에만 쓰는 계정 셋을 만든다 (이전 계획 1단계 5번).
#   repl_rds      RDS 가 binlog 를 받는 복제 계정 (REPLICATION SLAVE · CLIENT)
#   proxysql_mon  ProxySQL 감시 계정 (접속만)
#   dump_rds      덤프 계정. RELOAD · FLUSH_TABLES 를 주지 않아 MySQL Shell 이 전역 읽기 잠금(FLUSH TABLES WITH READ LOCK)
#                 대신 덤프 대상 표에 LOCK TABLES READ 를 건다. 전역 읽기 잠금은 긴 문장 뒤에서 기다리는 동안 모든 쓰기를 막고,
#                 끊어도 그 문장이 쓰던 표는 문장이 끝날 때까지 막힌 채로 남는다(로컬 확인). LOCK TABLES 는 끊으면 바로 풀린다.
#                 PROCESS 는 30-dump-load.sh 가 잠금 때문에 기다리는 세션을 보려고, mysql.* SELECT 는 MySQL Shell 의 권한 확인용이다
#
#   NCP_HOST NCP_PORT NCP_USER(nova_admin) NCP_PASSWORD   NCP 관리 계정
#   REPL_PASSWORD PROXYSQL_MON_PASSWORD DUMP_PASSWORD      만들 계정의 비밀번호
#   REPL_HOST                                              복제 계정의 호스트 (기본 %, 네트워크 제한은 ACG 가 맡는다)
#   APP_SCHEMAS                                            덤프할 DB (기본: shop external_mock)
#
# 30-dump-load.sh 보다 먼저 돌린다. 덤프 시점 이전의 계정 변경은 복제로 넘어가지 않으므로, RDS 의 복제 필터가 계정 관리문을
# 거르는지와 상관없이 RDS 계정(20-rds-accounts.sh)과 부딪히지 않는다.
# 여러 번 돌려도 된다(있으면 비밀번호와 권한만 맞춘다). nova_admin 에 전역 GRANT OPTION 이 있어야 한다(00-precheck.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD REPL_PASSWORD PROXYSQL_MON_PASSWORD DUMP_PASSWORD
read -r -a schemas <<<"${APP_SCHEMAS:-shop external_mock}"
repl_host="${REPL_HOST:-%}"
(($# == 0)) || die "인자를 받지 않는다: $*"
ident_ok REPL_HOST APP_SCHEMAS
runbook_lock
for v in REPL_PASSWORD PROXYSQL_MON_PASSWORD DUMP_PASSWORD; do
  [[ "${!v}" != *[\'\"\\]* ]] || die "$v 에 SQL 문자열에 넣을 수 없는 문자(' \" \\)가 있다"
done

dump_grants=""
for s in "${schemas[@]}"; do
  dump_grants+="GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON \`$s\`.* TO 'dump_rds'@'%';"$'\n'
done

log "NCP 계정: repl_rds@$repl_host, proxysql_mon@%, dump_rds@%"
ncp <<SQL
CREATE USER IF NOT EXISTS 'repl_rds'@'$repl_host' IDENTIFIED BY '$REPL_PASSWORD';
ALTER USER 'repl_rds'@'$repl_host' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl_rds'@'$repl_host';
CREATE USER IF NOT EXISTS 'proxysql_mon'@'%' IDENTIFIED BY '$PROXYSQL_MON_PASSWORD';
ALTER USER 'proxysql_mon'@'%' IDENTIFIED BY '$PROXYSQL_MON_PASSWORD';
CREATE USER IF NOT EXISTS 'dump_rds'@'%' IDENTIFIED BY '$DUMP_PASSWORD';
ALTER USER 'dump_rds'@'%' IDENTIFIED BY '$DUMP_PASSWORD';
GRANT PROCESS, REPLICATION CLIENT, BACKUP_ADMIN ON *.* TO 'dump_rds'@'%';
GRANT SELECT ON mysql.* TO 'dump_rds'@'%';
$dump_grants
SQL
ncp <<<"SHOW GRANTS FOR 'repl_rds'@'$repl_host'"
ncp <<<"SHOW GRANTS FOR 'dump_rds'@'%'"
