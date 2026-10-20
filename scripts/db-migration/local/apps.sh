#!/usr/bin/env bash
# 실제 be 서비스 이미지(release:catalog · release:preorder)를 ProxySQL 뒤에 붙인다. 프로브가 못 보는 것을 본다:
# Hibernate · Spring 이 보내는 문장이 ProxySQL 연결을 고정하지 않는지, 앱의 주기 작업(아웃박스 등)이 도는 중에 비우기가 되는지,
# 전환 중 HTTP 요청이 실패하거나 늦어지지 않는지.
#
#   scripts/db-migration/local/apps.sh up              Redis · Floci(SQS) 와 두 서비스를 띄우고 준비될 때까지 기다린다
#   scripts/db-migration/local/apps.sh load <초> <이름> catalog 공개 API 를 초당 약 10번 부르고 결과를 work/<이름>/http.tsv 에 남긴다
#   scripts/db-migration/local/apps.sh pinned          ProxySQL 에서 트랜잭션 없이 뒷단 연결을 쥔 세션과 @ 가 든 쿼리를 보여 준다
#   scripts/db-migration/local/apps.sh down
#
# 이미지는 be 의 docker/aot-training/train.sh 로 만든 것이다. 설정은 그 스크립트와 같은 방식(application.yml.example + 주소 ·
# 비밀값만 덮기)이고, DB 주소만 ProxySQL 로 둔다. preorder 는 proxysql1, catalog 는 proxysql2 로 붙는다.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
work="$PWD/work"
set -a
# shellcheck disable=SC1091
source "$work/local.env"
set +a
NET=dbmig_default
SERVICES="catalog preorder"
proxy_of() { if [[ $1 == preorder ]]; then echo proxysql1; else echo proxysql2; fi; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

app_json() { # app_json <서비스>
  local s=$1 pw
  pw="PW_$(tr '[:lower:]' '[:upper:]' <<<"$s")"
  python3 -I - "$s" "$(proxy_of "$s")" "${!pw}" <<'PY'
import json, sys
s, proxy, pw = sys.argv[1:4]
url = lambda svc: f"http://{svc}:8080"
d = {
  "server.port": 8080, "management.server.port": 8081,
  "spring.datasource.url": f"jdbc:mysql://{proxy}:3306/shop?serverTimezone=UTC&characterEncoding=UTF-8&sslMode=REQUIRED",
  "spring.datasource.username": s, "spring.datasource.password": pw,
  "spring.data.redis.host": "redis", "spring.data.redis.connect-timeout": "2s", "spring.data.redis.timeout": "2s",
  "nova.sqs.endpoint": "http://floci:4566",
  "jwt.issuer": "dbmig", "jwt.audience": "dbmig-api",
  "jwt.jwk-set-uri": url("member") + "/.well-known/jwks.json", "jwt.jwk-set-allow-http": True,
}
d.update({
  "catalog": {"spring.http.serviceclient.order.base-url": url("order"), "spring.http.serviceclient.member.base-url": url("member"),
              "catalog.registration.min-open-lead": "PT20S", "nova.upload.bucket": "dbmig", "nova.upload.region": "ap-northeast-2"},
  "preorder": {"spring.http.serviceclient.catalog.base-url": url("catalog"), "spring.http.serviceclient.order.base-url": url("order")},
}.get(s, {}))
print(json.dumps(d))
PY
}

case "${1:?up · load · pinned · down}" in
  up)
    for s in $SERVICES; do docker image inspect "release:$s" >/dev/null || { echo "release:$s 이미지가 없다(be docker/aot-training/train.sh)" >&2; exit 1; }; done
    log "Redis · Floci"
    docker compose --profile apps up -d --wait redis floci
    docker compose --profile apps run --rm floci-init >/dev/null
    for s in $SERVICES; do
      docker rm -f "dbmig-app-$s" >/dev/null 2>&1 || true
      git -C "${BE_REPO:-$HOME/Downloads/nova}" show "${BE_REF:-origin/dev}:$s/src/main/resources/application.yml.example" >"$work/be/$s.yml"
      chmod 644 "$work/be/$s.yml"
      docker run -d --name "dbmig-app-$s" --label dbmig-app --network "$NET" --network-alias "$s" --memory 2g \
        -v "$work/be/$s.yml:/config/application.yml:ro" -e SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/ \
        -e SPRING_APPLICATION_JSON="$(app_json "$s")" -e WAITING_TOKEN_SECRET="$(openssl rand -hex 24)" \
        -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_REGION=ap-northeast-2 \
        "release:$s" >/dev/null
    done
    log "준비 기다림 (최대 180초)"
    for _ in $(seq 90); do
      ok=1
      for s in $SERVICES; do
        docker compose exec -T tools curl -sf -o /dev/null "http://$s:8081/actuator/health/readiness" || ok=0
      done
      ((ok)) && { log "두 서비스 준비 완료"; exit 0; }
      sleep 2
    done
    for s in $SERVICES; do echo "── $s" >&2; docker logs --tail 40 "dbmig-app-$s" >&2 || true; done
    exit 1
    ;;
  load)
    secs="${2:?초}"
    out="/work/${3:?결과 이름}"
    mkdir -p "$work/$3"
    docker compose exec -T tools bash -c '
      end=$((SECONDS + $0)); : >"$1/http.tsv"
      while ((SECONDS < end)); do
        for p in "/api/v1/categories" "/api/v1/products?size=20"; do
          curl -s -o /dev/null --max-time 10 -w "%{http_code}\t%{time_total}\t$p\n" "http://catalog:8080$p" >>"$1/http.tsv" || echo "000	10	$p" >>"$1/http.tsv"
        done
        sleep 0.2
      done
      awk -F"\t" '"'"'{n++; if ($1 != 200) bad++; if ($2 > max) max = $2; if ($2 > 0.3) slow++; if ($2 > 1) vslow++}
        END {printf "HTTP %d건, 200 이 아닌 응답 %d, 최대 %.3f초, 0.3초 넘음 %d, 1초 넘음 %d\n", n, bad, max, slow, vslow}'"'"' "$1/http.tsv" | tee "$1/http-summary.txt"' "$secs" "$out"
    ;;
  pinned)
    docker compose exec -T tools bash -c '
      for n in proxysql1 proxysql2; do
        echo "== $n"
        mysql --defaults-extra-file=<(printf "[client]\nuser=radmin\npassword=\"%s\"\n" "$PW_PROXYSQL_ADMIN") --host=$n --port=6032 --ssl-mode=DISABLED --table -e "
          SELECT user, command, srv_host, time_ms, SUBSTR(COALESCE(info, \"\"), 1, 60) AS info FROM stats_mysql_processlist WHERE srv_host <> \"\";
          SELECT username, count_star, SUBSTR(digest_text, 1, 90) AS digest FROM stats_mysql_query_digest WHERE digest_text LIKE \"%@%\" ORDER BY count_star DESC;
          SELECT srv_host, ConnUsed, ConnFree FROM stats_mysql_connection_pool;"
      done'
    ;;
  down)
    docker rm -f $(docker ps -aq --filter label=dbmig-app) >/dev/null 2>&1 || true
    docker compose --profile apps rm -sf redis floci >/dev/null 2>&1 || true
    ;;
  *) echo "up · load · pinned · down" >&2; exit 1 ;;
esac
