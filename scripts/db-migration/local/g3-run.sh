#!/usr/bin/env bash
# G3 시나리오: 프로브(와 be 서비스 HTTP 요청)가 계속 도는 동안 NCP → RDS 로 전환하고, 다시 RDS → NCP 로 되돌린다.
#
#   scripts/db-migration/local/g3-run.sh
#
# 1단계(up.sh · 10 · 20 · 30 · read_only on · 40 start)가 끝난 환경에서 돈다. 출력은 LOGS(기본 work/logs/<시각>) 에 남는다.
#   1. 프로브 · HTTP 시작(쓰기 대상 ncp) → 15초 뒤 RDS read_only 해제(운영의 T-30분 PR 대신) → 60-cutover → 15초 → 정지 → RDS 대조
#   2. 프로브 · HTTP 다시 시작(쓰기 대상 rds) → 10초 → 70-rollback → 10초 → 정지 → NCP 대조
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGS="${LOGS:-work/logs/$(date -u +%Y%m%dT%H%M%S)}"
mkdir -p "$LOGS"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOGS/summary.txt" >&2; }
http() { [[ "$(docker ps -q --filter label=dbmig-app | wc -l | tr -d ' ')" -gt 0 ]]; }

run1="g3-cutover-$(date -u +%H%M%S)"
log "1) 프로브 시작 → $run1"
./probe.sh start "$run1"
load_pid=""
if http; then ./apps.sh load 45 "$run1" >"$LOGS/http-$run1.log" 2>&1 & load_pid=$!; fi
sleep 15
./read-only.sh off
log "전환"
./tools.sh 60-cutover.sh 2>&1 | tee "$LOGS/60-cutover.log"
sleep 15
[[ -z "$load_pid" ]] || wait "$load_pid" || { log "HTTP 요청이 실패했다($LOGS/http-*.log)"; exit 1; }
./probe.sh stop "$run1"
./verify.sh rds "$run1" 2>&1 | tee "$LOGS/verify-$run1.log"
{ grep -E '^[0-9:.]+ [567]\.' "$LOGS/60-cutover.log"; cat "$LOGS/verify-$run1.log"; cat "work/$run1/http-summary.txt" 2>/dev/null; } >>"$LOGS/summary.txt"

run2="g3-rollback-$(date -u +%H%M%S)"
log "2) 프로브 다시 시작 → $run2"
./probe.sh start "$run2"
load_pid=""
if http; then ./apps.sh load 35 "$run2" >"$LOGS/http-$run2.log" 2>&1 & load_pid=$!; fi
sleep 10
log "되돌리기"
./tools.sh 70-rollback.sh 2>&1 | tee "$LOGS/70-rollback.log"
sleep 10
[[ -z "$load_pid" ]] || wait "$load_pid" || { log "HTTP 요청이 실패했다($LOGS/http-*.log)"; exit 1; }
./probe.sh stop "$run2"
./verify.sh ncp "$run2" 2>&1 | tee "$LOGS/verify-$run2.log"
{ grep -E '되돌리기 끝|^[0-9:.]+ [3456]\.' "$LOGS/70-rollback.log"; cat "$LOGS/verify-$run2.log"; cat "work/$run2/http-summary.txt" 2>/dev/null; } >>"$LOGS/summary.txt"
