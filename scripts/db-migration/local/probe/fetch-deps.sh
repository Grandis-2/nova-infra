#!/usr/bin/env bash
# 프로브가 쓰는 jar 를 Maven Central 에서 받아 probe/lib 에 둔다(git 에 올리지 않음). 여기 고정한 SHA-256 으로 검증한다
# (같은 서버의 .sha1 은 서버 쪽 위변조를 막지 못한다). 버전을 올릴 때 해시도 함께 바꾼다.
# 버전은 be 와 같다: HikariCP 7.0.2 (Spring Boot 4.1.1 관리), Connector/J 9.7.0.
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
mkdir -p "$lib"
base=https://repo1.maven.org/maven2
for entry in \
  com.zaxxer:HikariCP:7.0.2=f1e612fa27345be3107a85431e8a8aeb205c15364ab2f2d411e40a9d7bb08095 \
  com.mysql:mysql-connector-j:9.7.0=0353648eaa1c91e0f4020c959abf756bc866ffd583df22ae6b6f6e0cbd43eb44 \
  org.slf4j:slf4j-api:2.0.17=7b751d952061954d5abfed7181c1f645d336091b679891591d63329c622eb832 \
  org.slf4j:slf4j-simple:2.0.17=ddfea59ac074c6d3e24ac2c38622d2d963895e17f70b38ed4bdae4d780be6964; do
  coord=${entry%%=*}
  want=${entry#*=}
  IFS=: read -r g a v <<<"$coord"
  jar="$a-$v.jar"
  # 이미 받은 jar 도 해시를 본다. 다르면 지우고 다시 받는다
  if [[ -s "$lib/$jar" ]]; then
    [[ "$(shasum -a 256 "$lib/$jar" | cut -c1-64)" == "$want" ]] && continue
    echo "SHA-256 불일치: $jar (이미 받은 파일). 다시 받는다" >&2
    rm -f "$lib/$jar"
  fi
  url="$base/${g//.//}/$a/$v/$jar"
  curl -fsSL "$url" -o "$lib/$jar.tmp"
  got=$(shasum -a 256 "$lib/$jar.tmp" | cut -c1-64)
  [[ "$want" == "$got" ]] || { echo "SHA-256 불일치: $jar" >&2; rm -f "$lib/$jar.tmp"; exit 1; }
  mv "$lib/$jar.tmp" "$lib/$jar"
  echo "받음 $jar"
done
