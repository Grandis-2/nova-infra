#!/usr/bin/env bash
# G3 로컬 시험 환경을 띄운다. 이미 떠 있으면 빠진 것만 채운다(여러 번 돌려도 된다).
#
#   scripts/db-migration/local/up.sh
#
#   BE_REPO  be 저장소 경로 (기본: ~/Downloads/nova)
#   BE_REF   스키마를 가져올 커밋 (기본: origin/dev)
#   WRITER   ProxySQL 이 처음 쓰기를 보낼 DB (기본: work/writer 파일, 없으면 ncp)
#
# 운영과 같은 스키마로 시험하려고 be 의 Flyway 마이그레이션 · init.sql 을 그대로 NCP 역할 DB 에 적용한다.
# 비밀번호는 work/local.env 에 처음 한 번 만든다(로컬 시험 전용, git 에 올리지 않음). 호스트 bash 3.2 에서도 돈다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$here/work"
mkdir -p "$work"
cd "$here"

BE_REPO="${BE_REPO:-$HOME/Downloads/nova}"
BE_REF="${BE_REF:-origin/dev}"
# be flyway-project/flyway.sh 와 같은 이미지 · digest
FLYWAY_IMAGE='redgate/flyway:11.20.0@sha256:c92844730f0cccd8f8c34997dfe6be106034df0a1faa186029ee554847b57be0'
APP_USERS="batch catalog member mock order payment preorder worker"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }

# ── 비밀번호 ────────────────────────────────────────────────
# NCP 규칙(20자, 대 · 소문자 · 숫자 · 특수문자)을 따른다. env 파일에서 해석되는 $ 는 뺐다.
if [[ ! -s "$work/local.env" ]]; then
  log "비밀번호 생성 → work/local.env"
  python3 -I - "$APP_USERS" >"$work/local.env" <<'PY'
import secrets, string, sys
special = "!#%*-_=?@^~"
alphabet = string.ascii_letters + string.digits + special
def pw():
    while True:
        p = "".join(secrets.choice(alphabet) for _ in range(20))
        if (any(c.islower() for c in p) and any(c.isupper() for c in p)
                and any(c.isdigit() for c in p) and any(c in special for c in p)):
            return p
users = sys.argv[1].split()
names = ["MYSQL_ROOT_PASSWORD", "PW_NOVA_ADMIN", "PW_NOVA_MIGRATOR", "PW_NOVA_EXPORTER", "PW_NOVA_MASTER",
         "PW_REPL_RDS", "PW_PROXYSQL_MON", "PW_PROXYSQL_ADMIN", "PW_DUMP_RDS"] + ["PW_" + u.upper() for u in users]
print(f"APP_USERS='{' '.join(users)}'")
for n in names:
    print(f"{n}='{pw()}'")
PY
  chmod 600 "$work/local.env"
fi
# 나중에 더한 계정의 비밀번호(이전에 만든 local.env 에 없을 때)
grep -q '^PW_DUMP_RDS=' "$work/local.env" || python3 -I -c 'import secrets, string; print("PW_DUMP_RDS=\x27" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)) + "\x27")' >>"$work/local.env"
set -a
# shellcheck disable=SC1091
source "$work/local.env"
set +a

# ── ProxySQL 설정 ───────────────────────────────────────────
# 운영에서는 config-init 컨테이너가 SSM 의 현재 쓰기 대상을 읽어 같은 파일을 만든다
writer="${WRITER:-$(cat "$work/writer" 2>/dev/null || echo ncp)}"
status_of() { if [[ "$1" == "$writer" ]]; then echo ONLINE; else echo OFFLINE_HARD; fi; }
{
  cat <<EOF
datadir="/var/lib/proxysql"
admin_variables=
{
  admin_credentials="admin:${PW_PROXYSQL_ADMIN};radmin:${PW_PROXYSQL_ADMIN}"
  mysql_ifaces="0.0.0.0:6032"
}
mysql_variables=
{
  threads=4
  max_connections=2048
  interfaces="0.0.0.0:3306"
  server_version="8.4.11"
  have_ssl=true
  default_authentication_plugin="caching_sha2_password"
  connect_timeout_server_max=30000
  # 자동 증가 값이 생긴 INSERT 뒤 몇 쿼리 동안 연결을 묶는 기능(LAST_INSERT_ID 용)을 끈다. 앱은 키를 INSERT 응답으로
  # 받고(getGeneratedKeys) LAST_INSERT_ID 를 따로 조회하지 않는다. 켜 두면 아웃박스를 쓰는 세션이 묶여 비울 수 없다
  auto_increment_delay_multiplex=0
  # 시험이 기다리지 않게 감시 주기를 줄인다(운영은 기본값 접속 60초 · ping 10초, 런북은 120초 안의 기록을 본다)
  monitor_connect_interval=5000
  monitor_ping_interval=2000
  monitor_username="proxysql_mon"
  monitor_password="${PW_PROXYSQL_MON}"
}
# 그룹 10 은 쓰기 대상, 11 은 감시 전용(두 서버를 늘 ONLINE 으로 둬 ProxySQL 감시가 계속 접속 · ping 한다. 이 그룹을 쓰는
# 계정 · 규칙은 없다). 런북은 전환 전에 11 의 감시 기록으로 ProxySQL 에서 받을 서버에 닿는지 본다(lib.sh px_reachable)
mysql_servers=
(
  { address="ncp", port=3306, hostgroup=10, status="$(status_of ncp)", use_ssl=1, max_connections=500, comment="ncp" },
  { address="rds", port=3306, hostgroup=10, status="$(status_of rds)", use_ssl=1, max_connections=500, comment="rds" },
  { address="ncp", port=3306, hostgroup=11, status="ONLINE", use_ssl=1, max_connections=1, comment="ncp monitor only" },
  { address="rds", port=3306, hostgroup=11, status="ONLINE", use_ssl=1, max_connections=1, comment="rds monitor only" }
)
# @@ 변수를 묻는 쿼리는 ProxySQL 의 멀티플렉싱을 끄고, 한 번 꺼지면 그 연결이 닫힐 때까지 뒷단 연결이 묶인다.
# 그러면 전환 때 OFFLINE_SOFT 로 비울 수 없다. 앱이 보내는 것은 셋이고, 이 쿼리들만 끄지 않게(multiplex=2) 한다.
#   10 · 11  Connector/J 가 연결마다 보내는 서버 변수 조회 · 읽기 전용 확인
#   12       Hibernate 가 기동할 때 한 번 보내는 조회(hibernate-core 7.4.5 MySQLServerConfiguration)
mysql_query_rules=
(
  { rule_id=10, active=1, match_digest="^SELECT @@session\\\\.auto_increment_increment", multiplex=2, apply=0, comment="Connector/J connect-time variables" },
  { rule_id=11, active=1, match_digest="^SELECT @@session\\\\.transaction_read_only", multiplex=2, apply=0, comment="Connector/J read-only check" },
  { rule_id=12, active=1, match_digest="^SELECT @@character_set_database ?, ?@@sql_mode", multiplex=2, apply=0, comment="Hibernate startup" }
)
mysql_users=
(
EOF
  sep=""
  for u in $APP_USERS; do
    v="PW_$(upper "$u")"
    printf '%s  { username="%s", password="%s", default_hostgroup=10, active=1 }' "$sep" "$u" "${!v}"
    sep=$',\n'
  done
  printf '\n)\n'
} >"$work/proxysql.cnf"
chmod 600 "$work/proxysql.cnf"

# ── be 스키마 ───────────────────────────────────────────────
log "be 스키마 가져오기 ($BE_REF)"
rm -rf "$work/be"
mkdir -p "$work/be"
git -C "$BE_REPO" archive "$BE_REF" flyway-project docs/external-mock-schema.sql docker/floci/create-queues.sh | tar -x -C "$work/be"

# ── 컨테이너 ────────────────────────────────────────────────
log "MySQL 두 대 기동"
docker compose up -d --wait ncp rds
docker compose up -d tools probe proxysql1 proxysql2

# 컨테이너 안에서 앱 계정으로 SQL 을 돌린다(비밀번호는 컨테이너 환경변수에서 읽는다)
run_sql() { # run_sql <host> <계정> <비밀번호 변수명> [DB]   (SQL 은 표준 입력)
  docker compose exec -T tools bash -c '
    mysql --defaults-extra-file=<(printf "[client]\nuser=\"%s\"\npassword=\"%s\"\n" "$1" "${!2}") \
      --host="$0" --ssl-mode=REQUIRED --default-character-set=utf8mb4 --batch '"${4:-}" "$1" "$2" "$3"
}

log "Flyway 마이그레이션 (ncp, nova_migrator)"
export FLYWAY_URL='jdbc:mysql://ncp:3306/shop?useSsl=true&trustServerCertificate=true'
export FLYWAY_USER=nova_migrator
export FLYWAY_PASSWORD="$PW_NOVA_MIGRATOR"
docker run --rm --platform linux/amd64 --network dbmig_default \
  --mount "type=bind,source=$work/be/flyway-project,target=/flyway/project,readonly" \
  --workdir /flyway/project -e FLYWAY_URL -e FLYWAY_USER -e FLYWAY_PASSWORD \
  "$FLYWAY_IMAGE" -configFiles=/flyway/project/flyway.toml -outputType=json migrate >"$work/flyway-migrate.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("  적용", d.get("migrationsExecuted"), "건, 스키마 버전", d.get("targetSchemaVersion"))' "$work/flyway-migrate.json"

log "init.sql (ncp, catalog) · Mock 스키마 (ncp, nova_migrator) · 프로브 표"
run_sql ncp catalog PW_CATALOG shop <"$work/be/flyway-project/init.sql"
if [[ -z "$(run_sql ncp nova_migrator PW_NOVA_MIGRATOR <<<"SELECT 1 FROM information_schema.tables WHERE table_schema='external_mock' LIMIT 1" | tail -n +2)" ]]; then
  run_sql ncp nova_migrator PW_NOVA_MIGRATOR <"$work/be/docs/external-mock-schema.sql"
fi
run_sql ncp nova_migrator PW_NOVA_MIGRATOR shop <<'SQL'
CREATE TABLE IF NOT EXISTS g3_probe_write (
  seq        BIGINT      NOT NULL PRIMARY KEY,
  pool       VARCHAR(16) NOT NULL,
  written_on CHAR(36)    NOT NULL,
  created_at DATETIME(6) NOT NULL
);
CREATE TABLE IF NOT EXISTS g3_probe_counter (
  id    INT    NOT NULL PRIMARY KEY,
  value BIGINT NOT NULL
);
INSERT IGNORE INTO g3_probe_counter VALUES (1, 0);
-- 아웃박스처럼 AUTO_INCREMENT 키를 쓰는 표 (ProxySQL 의 auto_increment_delay_multiplex 확인용)
CREATE TABLE IF NOT EXISTS g3_probe_outbox (
  id  BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  seq BIGINT NOT NULL
);
SQL

log "준비 완료. 표 수:"
run_sql ncp nova_migrator PW_NOVA_MIGRATOR <<<"SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema IN ('shop','external_mock') GROUP BY table_schema"
