#!/usr/bin/env bash
# 프로브가 "어느 서버에서 처리됐는지" 읽는 표(g3meta.server)를 두 서버에 서로 다른 값으로 만든다.
# g3meta 는 복제 필터(shop.% · external_mock.%) 밖이라 넘어가지 않으므로, 표와 앱 계정의 읽기 권한을 서버마다 따로 만든다.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
for host in ncp rds; do
  docker compose exec -T tools bash -c '
    mysql --defaults-extra-file=<(printf "[client]\nuser=root\npassword=\"%s\"\n" "$MYSQL_ROOT_PASSWORD") \
      --host="$0" --ssl-mode=REQUIRED --batch --skip-column-names' "$host" <<SQL
CREATE DATABASE IF NOT EXISTS g3meta;
CREATE TABLE IF NOT EXISTS g3meta.server (id INT NOT NULL PRIMARY KEY, name VARCHAR(8) NOT NULL);
INSERT IGNORE INTO g3meta.server VALUES (1, '$host');
GRANT SELECT ON g3meta.* TO 'preorder'@'%', 'catalog'@'%', 'member'@'%', 'mock'@'%';
SELECT CONCAT('$host: g3meta.server = ', name) FROM g3meta.server;
SQL
done
