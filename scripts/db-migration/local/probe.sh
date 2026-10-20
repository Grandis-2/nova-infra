#!/usr/bin/env bash
# 프로브를 켜고 끈다. 프로브는 앱과 같은 Java 25 · HikariCP · Connector/J 로 ProxySQL 을 거쳐 계속 쓰고 읽는다(probe/Probe.java).
#
#   scripts/db-migration/local/probe.sh start <이름>   결과는 work/<이름>/ 에 쌓인다
#   scripts/db-migration/local/probe.sh stop <이름>    멈추고 요약(summary.txt)이 나올 때까지 기다린다
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
name="${2:?결과 디렉터리 이름}"
case "${1:?start 또는 stop}" in
  start)
    rm -rf "work/$name"
    docker compose exec -d -e PROBE_OUT="/work/$name" probe \
      java -Dorg.slf4j.simpleLogger.defaultLogLevel=warn -cp '/probe/lib/*' /probe/Probe.java
    ;;
  stop)
    mkdir -p "work/$name"
    touch "work/$name/stop"
    for _ in $(seq 60); do
      [[ -s "work/$name/summary.txt" ]] && exit 0
      sleep 1
    done
    echo "60초 안에 요약이 나오지 않았다: work/$name" >&2
    exit 1
    ;;
  *) echo "start 또는 stop" >&2; exit 1 ;;
esac
