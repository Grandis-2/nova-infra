#!/usr/bin/env bash
# Grafana 프로비저닝이 오류 없이 읽히는지 본다(데이터소스 · 대시보드 · 경보).
# 경보는 실제로 SNS 로 보내지 않는다(주제가 없다). 규칙 · 알림 경로 · 템플릿이 읽히고, 템플릿이 Chatbot 이 받는 JSON 을 만드는지 본다.
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-grafana}"
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

up
A=(-s -u "admin:$GRAFANA_PASSWORD")

echo "── 데이터소스"
ds="$(curl "${A[@]}" "$GRAFANA/api/datasources" | python3 -I -c 'import sys,json; print(",".join(sorted(d["uid"] for d in json.load(sys.stdin))))')"
[ "$ds" = "loki,mimir,tempo" ] && pass "데이터소스: $ds" || fail "데이터소스가 다르다: $ds"
for uid in loki mimir tempo; do
  st="$(curl "${A[@]}" "$GRAFANA/api/datasources/uid/$uid/health" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("status"))')"
  [ "$st" = OK ] && pass "$uid 연결 확인 OK" || fail "$uid 연결 확인: $st"
done

echo "── 대시보드"
want="$(cd grafana/dashboards && ls ./*.json | wc -l | tr -d ' ')"
got="$(curl "${A[@]}" "$GRAFANA/api/search?type=dash-db&tag=nova" | python3 -I -c 'import sys,json; print(len(json.load(sys.stdin)))')"
[ "$got" = "$want" ] && pass "nova 대시보드 ${got}개가 프로비저닝됨" || fail "대시보드 $got / $want"
"${DC[@]}" logs grafana 2>&1 | grep -iE 'level=error.*(provision|dashboard)' && fail "Grafana 프로비저닝 오류 로그가 있다" || pass "프로비저닝 오류 로그 없음"

echo "── 경보"
rules="$(curl "${A[@]}" "$GRAFANA/api/v1/provisioning/alert-rules" | python3 -I -c 'import sys,json; print(" ".join(sorted(r["uid"] for r in json.load(sys.stdin))))')"
want_rules="$(grep -E '^      - uid: ' grafana/provisioning/alerting/rules.yaml | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$rules" = "$want_rules" ] && pass "경보 규칙: $rules" || fail "경보 규칙이 다르다: '$rules' / '$want_rules'"
cp="$(curl "${A[@]}" "$GRAFANA/api/v1/provisioning/contact-points?name=chatbot-sns")"
echo "$cp" | python3 -I -c 'import sys,json; c=json.load(sys.stdin); assert len(c)==1 and c[0]["type"]=="sns" and c[0]["settings"]["topic_arn"].startswith("arn:aws:sns:"), c' \
  && pass "알림 대상: SNS(주제는 환경 변수 SNS_TOPIC_ARN 에서)" || fail "SNS 알림 대상이 없거나 주제가 비었다"
# 규칙 질의가 PromQL 로 맞는지(문법 · 함수). 데이터가 없어도 success 여야 한다
python3 -I - "$MIMIR" <<'PY' && pass "규칙 질의 모두 Mimir 에서 문법 오류 없이 실행됨" || fail "실행되지 않는 규칙 질의가 있다"
import json, re, sys, urllib.parse, urllib.request
base = sys.argv[1]
bad = []
for m in re.finditer(r'^ +expr: (".*")$', open("grafana/provisioning/alerting/rules.yaml").read(), re.M):
    q = json.loads(m.group(1))
    r = json.load(urllib.request.urlopen(base + "/prometheus/api/v1/query?" + urllib.parse.urlencode({"query": q})))
    if r.get("status") != "success":
        bad.append((q, r))
for b in bad:
    print("    ", b)
sys.exit(1 if bad else 0)
PY
root="$(curl "${A[@]}" "$GRAFANA/api/v1/provisioning/policies" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["receiver"])')"
[ "$root" = chatbot-sns ] && pass "기본 알림 경로 → chatbot-sns" || fail "기본 알림 경로가 $root"

# 템플릿이 Chatbot 사용자 지정 알림 JSON 을 만드는지. 값에 " \ 줄바꿈이 섞인 경보로 렌더링해 본다
tpl="$(python3 -I - <<'PY'
import json
t = open("grafana/provisioning/alerting/notify.yaml").read()
body = t.split("template: |\n",1)[1].split("\ncontactPoints:",1)[0]
print(json.dumps("\n".join(l[6:] for l in body.splitlines())))
PY
)"
render="$(curl "${A[@]}" -X POST -H 'Content-Type: application/json' "$GRAFANA/api/alertmanager/grafana/config/api/v1/templates/test" -d @- <<JSON
{"name":"chatbot","template":$tpl,
 "alerts":[{"status":"firing","labels":{"alertname":"HTTP 5xx 비율","job":"nova/preorder"},
            "annotations":{"summary":"값 \"12%\"\n두 번째 줄 \\\\ 백슬래시"},"startsAt":"2026-10-12T00:00:00Z"}]}
JSON
)"
echo "$render" | python3 -I -c '
import sys, json
r = json.load(sys.stdin)
out = [x for x in r.get("results", []) if x["name"] == "chatbot.message"]
assert out, r
msg = json.loads(out[0]["text"])
assert msg["version"] == "1.0" and msg["source"] == "custom" and msg["content"]["textType"] == "client-markdown", msg
print("    title:", msg["content"]["title"]); print("    description:", msg["content"]["description"].strip())
' && pass "chatbot.message 가 Chatbot 사용자 지정 알림 JSON 이다(따옴표 · 줄바꿈 · 백슬래시가 든 값으로)" || fail "템플릿 렌더링 결과가 JSON 이 아니다: $render"

echo "통과"
