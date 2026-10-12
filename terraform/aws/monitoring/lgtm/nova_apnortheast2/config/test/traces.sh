#!/usr/bin/env bash
# 트레이스 경로를 본다: OTLP/HTTP → Collector(허용 목록 · tail sampling · 스팬 마스킹) → Tempo(S3) → Grafana
#   A. 오류 트레이스는 남고, 스팬 속성 · 이벤트 · 상태 메시지 · URL 쿼리의 원문이 저장되지 않는다
#   B. 1초 넘은 트레이스는 남는다
#   C. 헬스체크(/actuator/*) · 메시지 없는 SQS 롱폴링은 오류가 있어도(헬스체크) 버려진다
#   D. 빠르고 정상인 트레이스는 일부만 남는다(10%)
#   E. Grafana 의 Tempo 데이터소스(admin 로그인)로 읽힌다
#   F. 정상 종료하면 블록이 S3 에 오르고, 로컬 디스크를 비워도 S3 에서 읽힌다
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-traces}"
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# 트레이스 한 건(서버 스팬 + 자식 스팬)을 보낸다.
# 인자: trace_id, 서버 스팬 JSON 조각(속성 · 상태 · 이벤트), 길이(ms)
send_trace() {
  local tid="$1" server="$2" ms="${3:-20}" now end code
  now="$(python3 -I -c 'import time; print(time.time_ns())')"
  end=$((now + ms * 1000000))
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/traces" \
    -H 'Content-Type: application/json' -d @- <<JSON
{"resourceSpans":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"$SERVICE"}},
  {"key":"service.namespace","value":{"stringValue":"smoke"}},
  {"key":"deployment.environment","value":{"stringValue":"local"}},
  {"key":"process.pid","value":{"intValue":"4242"}}
 ]},
 "scopeSpans":[{"scope":{"name":"smoke"},"spans":[
  {"traceId":"$tid","spanId":"$(hex 8)","name":"server","kind":2,
   "startTimeUnixNano":"$now","endTimeUnixNano":"$end", $server},
  {"traceId":"$tid","spanId":"$(hex 8)","name":"SELECT orders","kind":3,
   "startTimeUnixNano":"$now","endTimeUnixNano":"$end",
   "attributes":[{"key":"db.query.text","value":{"stringValue":"select * from orders where id=?"}}]}
 ]}]}]}
JSON
)"
  [ "$code" = 200 ] || fail "Collector 응답 $code"
}

# Tempo 에서 trace_id 로 찾은 JSON(Go 의 \u003c 같은 이스케이프를 풀어 다시 쓴 것). 없으면 빈 문자열.
get_trace() {  # trace_id
  curl -s -f -H 'Accept: application/json' "$TEMPO/api/traces/$1" 2>/dev/null \
    | python3 -I -c 'import sys,json; print(json.dumps(json.load(sys.stdin), ensure_ascii=False))' 2>/dev/null || true
}

poll_trace() {  # trace_id [초]
  local out=""
  for _ in $(seq 1 "${2:-30}"); do
    out="$(get_trace "$1")"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  return 1
}

up

echo "── A. 오류 트레이스 · 스팬 마스킹"
T_ERR="$(hex 16)"
send_trace "$T_ERR" '"status":{"code":2,"message":"Duplicate entry '"'"'hong@example.com'"'"' for key '"'"'uk_member_email'"'"'"},
 "attributes":[
  {"key":"url.path","value":{"stringValue":"/orders"}},
  {"key":"url.query","value":{"stringValue":"phone=010-1234-5678&token=abc123"}},
  {"key":"url.full","value":{"stringValue":"http://order:8080/orders?phone=010-1234-5678&token=abc123"}},
  {"key":"member.contact","value":{"stringValue":"hong.gildong@example.com"}},
  {"key":"note","value":{"stringValue":"call +82 10-2222-3333 later"}},
  {"key":"order.id","value":{"stringValue":"0190a3e4-5b6c-7d8e-9f01-23456789abcd"}}],
 "events":[{"name":"exception","timeUnixNano":"'"$(python3 -I -c 'import time; print(time.time_ns())')"'",
  "attributes":[
   {"key":"exception.type","value":{"stringValue":"java.sql.SQLIntegrityConstraintViolationException"}},
   {"key":"exception.message","value":{"stringValue":"Duplicate entry '"'"'01099998888'"'"' for key '"'"'uk_phone'"'"'"}},
   {"key":"exception.stacktrace","value":{"stringValue":"java.sql.SQLException: user kim@example.org 010.4444.5555\n\tat com.grandis.nova.Order.save(Order.java:42)"}}]}]' 30
out="$(poll_trace "$T_ERR" 40)" || fail "오류 트레이스가 Tempo 에 없다 (tail sampling 이 남겨야 한다)"
pass "오류 트레이스가 Tempo 에 저장됨"
for raw in 010-1234-5678 abc123 hong.gildong@example.com hong@example.com 2222-3333 01099998888 kim@example.org 4444.5555; do
  echo "$out" | grep -qF "$raw" && fail "원문이 저장됐다: $raw"
done
pass "URL 쿼리 값 · 이메일 · 전화 · 중복 키 값 원문이 없다(속성 · 이벤트 · 상태 메시지)"
for want in 'phone=<masked>&token=<masked>' '?phone=<masked>&token=<masked>' '<masked:email>' '<masked:phone>' "Duplicate entry '<masked>' for key" '0190a3e4-5b6c-7d8e-9f01-23456789abcd' 'select * from orders where id=?' '/orders'; do
  echo "$out" | grep -qF "$want" || fail "기대한 값이 없다: $want"
done
pass "마스킹 표시가 있고, 식별자(UUID) · 경로 · SQL 은 그대로"
echo "$out" | grep -q 'process.pid' && fail "허용 목록 밖 process.pid 가 저장됐다"
pass "리소스 허용 목록: process.pid 는 버려짐"

echo "── B. 느린 트레이스"
T_SLOW="$(hex 16)"
send_trace "$T_SLOW" '"status":{"code":1},"attributes":[{"key":"url.path","value":{"stringValue":"/orders"}}]' 1500
poll_trace "$T_SLOW" 30 >/dev/null || fail "1.5초 트레이스가 남지 않았다"
pass "1초 넘은 정상 트레이스가 남음"

echo "── C. 헬스체크 · 빈 롱폴링은 버림"
T_HEALTH="$(hex 16)"
send_trace "$T_HEALTH" '"status":{"code":2,"message":"DOWN"},"attributes":[{"key":"url.path","value":{"stringValue":"/actuator/health/readiness"}}]' 1500
T_POLL="$(hex 16)"
send_trace "$T_POLL" '"kind":3,"status":{"code":0},"attributes":[{"key":"rpc.method","value":{"stringValue":"ReceiveMessage"}},{"key":"rpc.service","value":{"stringValue":"Sqs"}}]' 20000

echo "── D. 빠른 정상 트레이스 40건"
FAST=()
for _ in $(seq 1 40); do
  t="$(hex 16)"; FAST+=("$t")
  send_trace "$t" '"status":{"code":0},"attributes":[{"key":"url.path","value":{"stringValue":"/orders"}}]' 5
done
# 결정(decision_wait 10초)과 Tempo 반영을 기다린다. 위 A · B 가 이미 보인 뒤라 이만큼이면 충분하다.
sleep 25
[ -z "$(get_trace "$T_HEALTH")" ] && pass "헬스체크 트레이스는 오류여도 버려짐" || fail "헬스체크 트레이스가 저장됐다"
[ -z "$(get_trace "$T_POLL")" ] && pass "메시지 없는 ReceiveMessage 트레이스는 버려짐" || fail "빈 롱폴링 트레이스가 저장됐다"
kept=0
for t in "${FAST[@]}"; do [ -n "$(get_trace "$t")" ] && kept=$((kept + 1)); done
echo "    남은 빠른 트레이스: $kept / 40"
[ "$kept" -lt 40 ] && pass "빠른 정상 트레이스는 일부만 남음 ($kept/40, 기대 약 10%)" || fail "빠른 정상 트레이스가 모두 남았다 — 확률 샘플링이 걸리지 않았다"

echo "── E. Grafana"
code="$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_PASSWORD" "$GRAFANA/api/datasources/proxy/uid/tempo/api/traces/$T_ERR")"
[ "$code" = 200 ] && pass "Grafana(Tempo 데이터소스 프록시, admin 로그인)로 읽힘" || fail "Grafana 경유 응답 $code"
ds="$(curl -s -u "admin:$GRAFANA_PASSWORD" "$GRAFANA/api/datasources/uid/loki")"
echo "$ds" | grep -q '"datasourceUid":"tempo"' && pass "Loki 의 trace_id → Tempo 링크(derivedFields)가 프로비저닝됨" || fail "Loki derivedFields 가 없다"

echo "── F. 정상 종료 → S3 → 로컬 디스크를 비워도 S3 에서 읽힘"
"${DC[@]}" stop tempo >/dev/null
objs="$(s3_objects_in "$TEMPO_S3_BUCKET")"
echo "$objs" | sed 's/^/    /' | head -6
echo "$objs" | grep -q 'meta.json' || fail "S3 에 Tempo 블록(meta.json)이 없다 (flush_all_on_shutdown)"
pass "정상 종료 때 블록이 S3 에 올라감"
wipe "${OBS_DATA_DIR:?}/tempo"
"${DC[@]}" start tempo >/dev/null
wait_tempo
poll_trace "$T_ERR" 45 >/dev/null && pass "로컬 디스크를 비운 재기동 뒤에도 S3 에서 읽힘" || fail "재기동 뒤 S3 에서 못 읽음"

echo "통과"
