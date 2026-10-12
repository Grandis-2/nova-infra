#!/usr/bin/env bash
# 서비스별 Grafana 대시보드(<서비스>.json)를 한 틀에서 만든다. 손으로 8벌을 고치지 않는다.
#   bash grafana/dashboards/gen.sh            # config/ 에서. 만든 파일은 커밋한다
# 서비스 목록은 be 서비스(terraform/application/<키>)다. mock 은 be 앱이 아니라 뺐다.
# job 라벨은 Mimir 가 OTLP 리소스로 만든 <service.namespace>/<service.name> 이다(앱의 OTEL_SERVICE_NAME=<서비스>, service.namespace=nova).
#
# 지표 이름은 에이전트 2.32.0 이 실제로 낸 것을 Mimir(접미사 켬)에서 확인했다:
#   http_server_request_duration_seconds_*, jvm_memory_used_bytes{jvm_memory_type="heap"}, jvm_memory_limit_bytes,
#   jvm_gc_duration_seconds_*, jvm_thread_count, jvm_cpu_recent_utilization_ratio
# DB 커넥션 풀은 HikariCP 계측이 내는 이름이 semconv 단계에 따라 다르다(db_client_connections_usage · db_client_connection_count). 둘 다 본다(미확인).
# HTTP 는 에이전트 지표 하나만 쓴다(Actuator 의 http_server_requests_* 는 쓰지 않는다).
set -euo pipefail
cd "$(dirname "$0")"
SERVICES="${SERVICES:-batch catalog member order payment preorder waitingroom worker}"
NAMESPACE="${NAMESPACE:-nova}"

for svc in $SERVICES; do
  python3 -I - "$svc" "$NAMESPACE" > "$svc.json" <<'PY'
import json, sys
svc, ns = sys.argv[1], sys.argv[2]
job = f'job="{ns}/{svc}"'
M = {"type": "prometheus", "uid": "mimir"}
L = {"type": "loki", "uid": "loki"}
T = {"type": "tempo", "uid": "tempo"}
panels, y = [], 0

def row(title):
    global y
    panels.append({"type": "row", "title": title, "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})
    y += 1

def ts(title, targets, unit, x, w=8, h=8, desc=""):
    panels.append({
        "type": "timeseries", "title": title, "description": desc, "datasource": M,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
        "targets": [dict(datasource=M, refId=chr(65 + i), expr=e, legendFormat=l, exemplar=True) for i, (e, l) in enumerate(targets)],
    })

row("HTTP (에이전트 지표)")
ts("요청 수", [(f'sum by (http_route) (rate(http_server_request_duration_seconds_count{{{job}}}[$__rate_interval]))', "{{http_route}}")], "reqps", 0)
ts("오류율 (5xx)", [(f'sum(rate(http_server_request_duration_seconds_count{{{job}, http_response_status_code=~"5.."}}[$__rate_interval])) / sum(rate(http_server_request_duration_seconds_count{{{job}}}[$__rate_interval]))', "5xx")], "percentunit", 8)
ts("P99 응답 시간", [(f'histogram_quantile(0.99, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket{{{job}}}[$__rate_interval])))', "{{http_route}}")], "s", 16,
   desc="점(exemplar)을 누르면 그 요청의 트레이스로 간다")
y += 8
row("JVM")
ts("힙", [(f'sum by (instance) (jvm_memory_used_bytes{{{job}, jvm_memory_type="heap"}})', "사용 {{instance}}"),
          (f'sum by (instance) (jvm_memory_limit_bytes{{{job}, jvm_memory_type="heap"}})', "한도 {{instance}}")], "bytes", 0, w=6)
ts("GC 시간 비율", [(f'sum by (instance) (rate(jvm_gc_duration_seconds_sum{{{job}}}[$__rate_interval]))', "{{instance}}")], "percentunit", 6, w=6)
ts("스레드", [(f'sum by (instance) (jvm_thread_count{{{job}}})', "{{instance}}")], "short", 12, w=6)
ts("CPU", [(f'avg by (instance) (jvm_cpu_recent_utilization_ratio{{{job}}})', "{{instance}}")], "percentunit", 18, w=6)
y += 8
row("DB 커넥션 풀")
ts("커넥션 (상태별)", [(f'sum by (state) (db_client_connections_usage{{{job}}} or db_client_connection_count{{{job}}})', "{{state}}")], "short", 0, w=12,
   desc="HikariCP. 이름이 semconv 단계에 따라 달라 두 이름을 같이 본다")
ts("커넥션 대기 (P99)", [(f'histogram_quantile(0.99, sum by (le) (rate(db_client_connections_wait_time_seconds_bucket{{{job}}}[$__rate_interval]) or rate(db_client_connection_wait_time_seconds_bucket{{{job}}}[$__rate_interval])))', "P99")], "s", 12, w=12)
y += 8
row("로그 · 트레이스")
panels.append({"type": "logs", "title": "WARN · ERROR 로그", "datasource": L, "gridPos": {"h": 10, "w": 12, "x": 0, "y": y},
               "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True},
               "targets": [{"datasource": L, "refId": "A", "expr": f'{{service_name="{svc}", service_namespace="{ns}"}} | severity_text=~"WARN|ERROR"'}]})
panels.append({"type": "table", "title": "오류 트레이스", "datasource": T, "gridPos": {"h": 10, "w": 12, "x": 12, "y": y},
               "targets": [{"datasource": T, "refId": "A", "queryType": "traceql", "limit": 20,
                            "query": f'{{resource.service.name="{svc}" && resource.service.namespace="{ns}" && status=error}}'}]})
y += 10

print(json.dumps({
    "uid": f"{ns}-{svc}", "title": f"{ns} · {svc}", "tags": [ns, "service"], "editable": False,
    "schemaVersion": 39, "time": {"from": "now-6h", "to": "now"}, "refresh": "1m", "timezone": "browser",
    "panels": [dict(p, id=i + 1) for i, p in enumerate(panels)],
}, ensure_ascii=False, indent=2))
PY
done
echo "만듦: $(ls ./*.json | wc -l | tr -d ' ')개"
