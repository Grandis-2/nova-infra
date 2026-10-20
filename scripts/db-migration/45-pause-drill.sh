#!/usr/bin/env bash
# 쓰기 대상은 그대로 두고 "대기 → 재개"만 되풀이한다 (이전 계획 2단계 2번).
# 전환 · 되돌리기와 같은 순서(조용한 순간 → OFFLINE_SOFT → 비우기 → ONLINE)가 예산 안에 끝나는지, 요청이 얼마나 기다리는지 잰다.
#
#   PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD (lib.sh)
#   PROXYSQL_FROM (기본 ncp)   CYCLES (기본 20)   GAP_SECONDS (기본 2)   BUDGET_MS (기본 300)   BUDGET_MARGIN_MS (기본 50, 60 과 같다)
#
# 비우기가 예산을 넘으면 그 회차는 바로 ONLINE 으로 돌리고 "넘음"으로 센다. 어떻게 끝나든 모든 노드를 ONLINE 으로 맞춘다.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
need PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD
from="${PROXYSQL_FROM:-ncp}"
cycles="${CYCLES:-20}"
gap="${GAP_SECONDS:-2}"
budget="${BUDGET_MS:-300}"
margin="${BUDGET_MARGIN_MS:-50}"
(($# == 0)) || die "인자를 받지 않는다: $*"
ident_ok PROXYSQL_FROM
runbook_lock
guard_rehearsal

paused=0
on_exit() {
  local rc=$1
  if ((paused)); then
    px_settle "$from" "-" back || rc=1
  fi
  return "$rc"
}
ON_EXIT=on_exit

px_open
px_state "$from" || die "ProxySQL 상태를 읽지 못했다: $(px_state_text)"
px_all ONLINE || die "$from 이 ONLINE 이 아닌 노드가 있다: $(px_state_text)"

total=0
max=0
over=0
for i in $(seq "$cycles"); do
  px_wait_quiet "$from"
  paused=1
  t0=$(ms)
  px_set $((budget - margin)) "$from=OFFLINE_SOFT" || die "$i 회째 OFFLINE_SOFT 를 싣지 못한 노드: $PX_FAILED"
  t1=$(ms)
  deadline=$((t0 + budget - (t1 - t0) - margin))
  while :; do
    rem=$((deadline - $(ms)))
    if ((rem <= 0)); then
      over=$((over + 1))
      log "$i 회째 비우기가 예산을 넘었다(묶인 연결 $PX_USED). 쥔 세션:"
      px_holders "$from"
      break
    fi
    if px_used "$from" "$rem" && ((PX_USED == 0)); then break; fi
  done
  px_set 2000 "$from=ONLINE" || die "$i 회째 ONLINE 으로 되돌리지 못한 노드: $PX_FAILED"
  paused=0
  d=$(($(ms) - t0))
  total=$((total + d))
  ((d <= max)) || max=$d
  log "$i/$cycles 대기 $d ms"
  sleep "$gap"
done
px_state "$from" || true
log "끝. $cycles 회, 대기 평균 $((total / cycles)) ms · 최대 $max ms, 예산(${budget} ms) 넘음 $over 회. 상태: $(px_state_text)"
((over == 0))
