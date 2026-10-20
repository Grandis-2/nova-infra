#!/usr/bin/env bash
# G3 로컬 시험을 빈 환경에서 처음부터 끝까지 돌린다. 단계마다 출력을 work/logs/<시각>/ 에 남긴다.
#
#   scripts/db-migration/local/g3-all.sh            APPS=0 이면 be 서비스 이미지를 붙이지 않는다
#
# 운영과 같은 순서로 진행한다.
#   up → 00 점검 → 10 NCP 계정 → 40 g2(연결만 시험) → 20 RDS 계정 → 프로브 서버 표 → 30 덤프 · 적재 → read_only on → 40 복제
#   → be 서비스 붙이기 · 고정 세션 점검 → 45 대기 · 재개 → g3-run(전환 · 되돌리기)
# 30 · 40 동안에도 프로브를 돌려, 덤프 시작 때 거는 잠금이 쓰기를 얼마나 기다리게 하는지 재고 복제로 빠짐없이 넘어갔는지 본다.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export LOGS="${LOGS:-work/logs/$(date -u +%Y%m%dT%H%M%S)}"
mkdir -p "$LOGS"
log() { printf '\n%s ## %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOGS/summary.txt" >&2; }
step() { # step <이름> <명령...>   출력을 로그 파일과 화면에 함께 남긴다
  local name=$1
  shift
  "$@" 2>&1 | tee "$LOGS/$name.log"
}

log "환경 지우기"
./apps.sh down >/dev/null 2>&1 || true
docker compose --profile apps down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf work/dump-* work/rollback-* work/g3-* work/probe work/writer work/dump-coords.env work/fault
mkdir -p work/fault
echo ncp >work/writer
log "up"
step up ./up.sh
log "00 점검"
step 00-precheck docker compose exec -T -e NCP_HOST=ncp -e NCP_PORT=3306 -e NCP_USER=nova_admin tools bash -c 'NCP_PASSWORD="$PW_NOVA_ADMIN" /scripts/00-precheck.sh'
sed -n '/## G1 판정/,$p' "$LOGS/00-precheck.log" >>"$LOGS/summary.txt"
log "10 NCP 계정 · 40 g2 · 20 RDS 계정 · 프로브 서버 표"
step 10-ncp-users ./tools.sh 10-ncp-users.sh
step 40-g2 ./tools.sh 40-replication.sh g2
grep -E 'G2' "$LOGS/40-g2.log" >>"$LOGS/summary.txt"
step 20-rds-accounts ./tools.sh 20-rds-accounts.sh
./probe-meta.sh

run0="g3-dump-$(date -u +%H%M%S)"
log "30 · 40 (프로브 → $run0)"
./probe.sh start "$run0"
sleep 10
step 30-dump-load ./tools.sh 30-dump-load.sh
grep -E '덤프 끝|복제 시작점|적재 끝|checksums were verified|warnings were reported' "$LOGS/30-dump-load.log" >>"$LOGS/summary.txt" || true
./read-only.sh on
step 40-start ./tools.sh 40-replication.sh start
sleep 10
./probe.sh stop "$run0"
sleep 3 # 마지막 쓰기가 복제로 넘어갈 시간
step "verify-$run0" ./verify.sh rds "$run0"
cat "$LOGS/verify-$run0.log" >>"$LOGS/summary.txt"

if [[ "${APPS:-1}" == 1 ]]; then
  log "be 서비스(catalog · preorder) 붙이기 · 고정 세션 점검"
  step apps-up ./apps.sh up
  sleep 20
  step apps-pinned ./apps.sh pinned
fi

run1="g3-pause-$(date -u +%H%M%S)"
log "45 대기 · 재개 (프로브 → $run1)"
./probe.sh start "$run1"
load_pid=""
if [[ "${APPS:-1}" == 1 ]]; then ./apps.sh load 60 "$run1" >"$LOGS/http-$run1.log" 2>&1 & load_pid=$!; fi
sleep 5
step 45-pause-drill ./tools.sh 45-pause-drill.sh
[[ -z "$load_pid" ]] || wait "$load_pid" || { log "HTTP 요청이 실패했다($LOGS/http-$run1.log)"; exit 1; }
./probe.sh stop "$run1"
step "verify-$run1" ./verify.sh ncp "$run1"
{ grep -E '끝\.' "$LOGS/45-pause-drill.log"; cat "$LOGS/verify-$run1.log"; cat "work/$run1/http-summary.txt" 2>/dev/null; } >>"$LOGS/summary.txt"

log "g3-run"
./g3-run.sh
log "끝. 결과: $LOGS/summary.txt"
