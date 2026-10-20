#!/usr/bin/env bash
# 프로브 실행 결과를 지금 쓰기 대상 DB 와 대조한다.
#
#   scripts/db-migration/local/verify.sh <ncp|rds> <프로브 결과 디렉터리(work/ 아래)>
#
#   잃은 쓰기     프로브가 확인 응답을 받았는데 DB 에 없는 쓰기 (전환 뒤 옛 DB 에 써진 쓰기도 여기서 드러난다)
#   카운터        경합 행 카운터 = 쓰기 표 행 수 (다르면 갱신이 사라졌다)
#   아웃박스      이번 실행의 쓰기가 AUTO_INCREMENT 표에도 모두 있는지
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
db="${1:?ncp 또는 rds}"
run="${2:?프로브 결과 디렉터리}"
q() {
  docker compose exec -T tools bash -c '
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=\"%s\"\n" "$MYSQL_ROOT_PASSWORD") \
      --host="$0" --ssl-mode=REQUIRED --batch --skip-column-names shop' "$db"
}
acked="work/$run/acked.txt"
[[ -s "$acked" ]] || { echo "확인 응답 목록이 없다: $acked" >&2; exit 1; }
lo=$(head -n1 "$acked")
hi=$(tail -n1 "$acked")

q <<<"SELECT seq FROM g3_probe_write WHERE seq BETWEEN $lo AND $hi ORDER BY seq" >"work/$run/present-$db.txt"
q <<<"SELECT seq FROM g3_probe_outbox WHERE seq BETWEEN $lo AND $hi ORDER BY seq" >"work/$run/outbox-$db.txt"
lost=$(comm -23 <(sort "$acked") <(sort "work/$run/present-$db.txt") | wc -l | tr -d ' ')
outbox_missing=$(comm -23 <(sort "$acked") <(sort "work/$run/outbox-$db.txt") | wc -l | tr -d ' ')
read -r counter rows <<<"$(q <<<"SELECT (SELECT value FROM g3_probe_counter WHERE id = 1), (SELECT COUNT(*) FROM g3_probe_write)")"

echo "== $db 대조 ($run, 번호 $lo ~ $hi)"
echo "확인 응답 받은 쓰기 $(wc -l <"$acked" | tr -d ' ')건, DB 에 없는 쓰기 ${lost}건, 아웃박스에 없는 쓰기 ${outbox_missing}건"
echo "카운터 ${counter}, 쓰기 표 행 수 ${rows} → $([[ "$counter" == "$rows" ]] && echo 일치 || echo 불일치)"
echo "이번 실행의 쓰기가 처리된 서버:"
q <<<"SELECT CONCAT('  ', written_on, ' ', COUNT(*)) FROM g3_probe_write WHERE seq BETWEEN $lo AND $hi GROUP BY written_on"
cat "work/$run/summary.txt"
echo "지연이 컸던 1초 구간:"
tail -n +2 "work/$run/timeline.tsv" | sort -t$'\t' -k6 -n -r | head -n 3 |
  awk -F'\t' '{ printf "  %s 최대 %sms, 쓰기 %s(오류 %s), 읽기 %s(오류 %s), 서버 %s\n", substr($1, 12, 12), $6, $2, $3, $4, $5, $7 }'
[[ "$lost" == 0 && "$outbox_missing" == 0 && "$counter" == "$rows" ]]
