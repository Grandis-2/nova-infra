#!/usr/bin/env bash
# 지표 경로를 본다: OTLP/HTTP → Collector(허용 목록) → Mimir(S3) → Grafana
#   A. OTLP 히스토그램 · 카운터가 PromQL 로 읽힌다(이름 · 단위 접미사 · job 라벨 · 올린 리소스 속성)
#   B. 허용 목록 밖 리소스 속성(process.pid)은 target_info 에도 없다
#   C. Collector 가 자기 지표를 긁어 넣는다. mysqld_exporter 대상이 비면 긁지 않고 Collector 는 떠 있다
#   D. Grafana 의 Mimir 데이터소스(admin 로그인)로 읽힌다
#   E. 정상 종료하면 블록이 S3 에 오르고, 로컬 디스크를 비워도 S3 에서 읽힌다
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-metrics}"
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

# PromQL 결과 시계열 수
series() {  # query [기준 URL] [curl 옵션...]
  local q="$1" base="${2:-$MIMIR/prometheus}"; shift; [ $# -gt 0 ] && shift
  curl -s -G "$@" "$base/api/v1/query" --data-urlencode "query=$q" \
    | python3 -I -c 'import sys,json; d=json.load(sys.stdin); print(len(d["data"]["result"]))' 2>/dev/null || echo 0
}

poll_series() {  # query [초]
  local n=0
  for _ in $(seq 1 "${2:-30}"); do
    n="$(series "$1")"
    [ "$n" -ge 1 ] && { echo "$n"; return 0; }
    sleep 2
  done
  echo "$n"
}

send_metrics() {
  local now start code
  now="$(python3 -I -c 'import time; print(time.time_ns())')"
  start=$((now - 30000000000))
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/metrics" \
    -H 'Content-Type: application/json' -d @- <<JSON
{"resourceMetrics":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"$SERVICE"}},
  {"key":"service.namespace","value":{"stringValue":"smoke"}},
  {"key":"deployment.environment","value":{"stringValue":"local"}},
  {"key":"process.pid","value":{"intValue":"4242"}}
 ]},
 "scopeMetrics":[{"scope":{"name":"smoke"},"metrics":[
  {"name":"http.server.request.duration","unit":"s","histogram":{"aggregationTemporality":2,"dataPoints":[
    {"startTimeUnixNano":"$start","timeUnixNano":"$now","count":"3","sum":0.6,
     "explicitBounds":[0.1,0.5,1],"bucketCounts":["1","1","1","0"],
     "attributes":[{"key":"http.route","value":{"stringValue":"/orders"}},
                   {"key":"http.request.method","value":{"stringValue":"GET"}},
                   {"key":"http.response.status_code","value":{"intValue":"200"}}]}]}},
  {"name":"smoke.events","unit":"1","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[
    {"startTimeUnixNano":"$start","timeUnixNano":"$now","asInt":"7"}]}}
 ]}]}]}
JSON
)"
  [ "$code" = 200 ] && pass "Collector 가 받음 (HTTP 200)" || fail "Collector 응답 $code"
}

up
JOB="smoke/$SERVICE"

echo "── A. OTLP 지표 → PromQL"
send_metrics
n="$(poll_series "http_server_request_duration_seconds_count{job=\"$JOB\"}" 40)"
[ "$n" -ge 1 ] && pass "히스토그램: http_server_request_duration_seconds_count{job=\"$JOB\"} → ${n}개" || fail "히스토그램이 Mimir 에 없다"
# 질의 문자열은 변수에 먼저 담는다. "$( … "{a, b}" … )" 안에서는 중괄호가 확장되어 질의가 잘린다
q="http_server_request_duration_seconds_bucket{job=\"$JOB\", http_route=\"/orders\", le=\"0.5\"}"
[ "$(poll_series "$q" 15)" -ge 1 ] \
  && pass "버킷 · 속성 라벨(http_route · le)" || fail "버킷 시계열이 없다"
n="$(poll_series "smoke_events_total{job=\"$JOB\"}" 10)"
[ "$n" -ge 1 ] && pass "카운터: smoke_events_total" || fail "카운터가 Mimir 에 없다"
q="http_server_request_duration_seconds_count{job=\"$JOB\", deployment_environment=\"local\", service_namespace=\"smoke\"}"
[ "$(poll_series "$q" 15)" -ge 1 ] \
  && pass "리소스 속성 deployment.environment · service.namespace 가 라벨로 올라감" || fail "올린 리소스 속성이 라벨에 없다"

echo "── B. 허용 목록"
[ "$(poll_series "target_info{job=\"$JOB\"}" 10)" -ge 1 ] || fail "target_info 가 없다"
q="target_info{job=\"$JOB\", process_pid!=\"\"}"
[ "$(series "$q")" = 0 ] && pass "process.pid 는 target_info 에도 없다" || fail "process.pid 가 허용 목록을 통과했다"

echo "── C. 긁어 오는 지표"
# job 은 scrape_configs 의 이름(otel-collector)이 아니라 Collector 자기 지표의 service.name(otelcol-contrib)이 된다
n="$(poll_series 'up{job="otelcol-contrib"} == 1' 40)"
[ "$n" -ge 1 ] && pass "Collector 자기 지표를 긁음 (up{job=\"otelcol-contrib\"} = 1)" || fail "Collector 자기 지표가 없다"
[ "$(poll_series 'otelcol_receiver_accepted_metric_points_total' 15)" -ge 1 ] \
  && pass "otelcol_receiver_accepted_metric_points_total 이 있다(수집 경로 경보가 쓴다)" || fail "otelcol 수신 지표가 없다"
[ "$(series 'up{job="mysqld"}')" = 0 ] && pass "MYSQLD_EXPORTER_TARGET 이 비면 mysqld 를 긁지 않는다" || fail "빈 대상인데 mysqld 시계열이 있다"
[ "$("${DC[@]}" ps --status running -q otel-collector | wc -l | tr -d ' ')" = 1 ] && pass "빈 대상에도 Collector 는 떠 있다" || fail "Collector 가 떠 있지 않다"

echo "── D. Grafana"
n="$(series "http_server_request_duration_seconds_count{job=\"$JOB\"}" "$GRAFANA/api/datasources/proxy/uid/mimir" -u "admin:$GRAFANA_PASSWORD")"
[ "$n" -ge 1 ] && pass "Grafana(Mimir 데이터소스 프록시, admin 로그인)로 읽힘" || fail "Grafana 경유로 못 읽음"

echo "── E. 정상 종료 → S3 → 로컬 디스크를 비워도 S3 에서 읽힘"
"${DC[@]}" stop mimir >/dev/null
objs="$(s3_objects_in "$MIMIR_S3_BUCKET")"
echo "$objs" | sed 's/^/    /' | head -6
echo "$objs" | grep -q 'blocks/.*/meta.json' || fail "S3 에 Mimir 블록(blocks/…/meta.json)이 없다 (flush_blocks_on_shutdown)"
pass "정상 종료 때 블록이 S3 의 blocks/ 접두사에 올라감"
wipe "${OBS_DATA_DIR:?}/mimir"
"${DC[@]}" start mimir >/dev/null
wait_mimir
# 표본이 몇 분 전 것이라 순간 질의는 비어 보일 수 있다(5분 조회 창). 1시간 창으로 본다.
# 재기동 뒤 compactor 가 버킷 인덱스를 쓰고 store-gateway 가 다시 훑어야(sync_interval 1분) 보인다
n="$(poll_series "last_over_time(http_server_request_duration_seconds_count{job=\"$JOB\"}[1h])" 120)"
[ "$n" -ge 1 ] && pass "로컬 디스크를 비운 재기동 뒤에도 S3 에서 읽힘" || fail "재기동 뒤 S3 에서 못 읽음"

echo "통과"
