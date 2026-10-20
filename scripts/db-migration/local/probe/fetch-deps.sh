#!/usr/bin/env bash
# 프로브가 쓰는 jar 를 Maven Central 에서 받아 probe/lib 에 둔다(git 에 올리지 않음). SHA-1 로 검증한다.
# 버전은 be 와 같다: HikariCP 7.0.2 (Spring Boot 4.1.1 관리), Connector/J 9.7.0.
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
mkdir -p "$lib"
base=https://repo1.maven.org/maven2
for coord in com.zaxxer:HikariCP:7.0.2 com.mysql:mysql-connector-j:9.7.0 org.slf4j:slf4j-api:2.0.17 org.slf4j:slf4j-simple:2.0.17; do
  IFS=: read -r g a v <<<"$coord"
  jar="$a-$v.jar"
  [[ -s "$lib/$jar" ]] && continue
  url="$base/${g//.//}/$a/$v/$jar"
  curl -fsSL "$url" -o "$lib/$jar.tmp"
  want=$(curl -fsSL "$url.sha1" | cut -c1-40)
  got=$(shasum -a 1 "$lib/$jar.tmp" | cut -c1-40)
  [[ "$want" == "$got" ]] || { echo "SHA-1 불일치: $jar" >&2; rm -f "$lib/$jar.tmp"; exit 1; }
  mv "$lib/$jar.tmp" "$lib/$jar"
  echo "받음 $jar"
done
