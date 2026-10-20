#!/bin/bash
# NCP 역할 MySQL 의 계정 · DB. 컨테이너가 처음 뜰 때 root 로 한 번 돈다.
# 권한은 G1(10/19)에서 읽은 운영 NCP 의 SHOW GRANTS 와 같다(DDL · CRUD · READ 세 단계). RELOAD · SUPER · CONNECTION_ADMIN 은 없다.
set -euo pipefail
sql() { mysql -uroot -p"$MYSQL_ROOT_PASSWORD"; }

ddl() { cat <<SQL
CREATE USER '$1'@'%' IDENTIFIED BY '$2';
GRANT PROCESS, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT, CREATE USER ON *.* TO '$1'@'%' WITH GRANT OPTION;
GRANT BACKUP_ADMIN, FLUSH_TABLES, SHOW_ROUTINE, XA_RECOVER_ADMIN ON *.* TO '$1'@'%' WITH GRANT OPTION;
GRANT SELECT ON mysql.* TO '$1'@'%' WITH GRANT OPTION;
GRANT SELECT, EXECUTE ON sys.* TO '$1'@'%' WITH GRANT OPTION;
GRANT SELECT ON performance_schema.* TO '$1'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON shop.* TO '$1'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON external_mock.* TO '$1'@'%' WITH GRANT OPTION;
GRANT INSERT, UPDATE, DELETE ON mysql.time_zone_leap_second TO '$1'@'%';
GRANT INSERT, UPDATE, DELETE ON mysql.time_zone_name TO '$1'@'%';
GRANT INSERT, UPDATE, DELETE ON mysql.time_zone_transition_type TO '$1'@'%';
GRANT INSERT, UPDATE, DELETE ON mysql.time_zone_transition TO '$1'@'%';
GRANT INSERT, UPDATE, DELETE ON mysql.time_zone TO '$1'@'%';
SQL
}

crud() { cat <<SQL
CREATE USER '$1'@'%' IDENTIFIED BY '$2';
GRANT PROCESS, SHOW DATABASES, REPLICATION CLIENT ON *.* TO '$1'@'%';
GRANT SELECT ON mysql.* TO '$1'@'%';
GRANT SELECT, EXECUTE ON sys.* TO '$1'@'%';
GRANT SELECT ON performance_schema.* TO '$1'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW, EVENT ON shop.* TO '$1'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW, EVENT ON external_mock.* TO '$1'@'%';
SQL
}

read_only() { cat <<SQL
CREATE USER '$1'@'%' IDENTIFIED BY '$2';
GRANT PROCESS, SHOW DATABASES, REPLICATION CLIENT ON *.* TO '$1'@'%';
GRANT SELECT ON mysql.* TO '$1'@'%';
GRANT SELECT, EXECUTE ON sys.* TO '$1'@'%';
GRANT SELECT ON performance_schema.* TO '$1'@'%';
GRANT SELECT, LOCK TABLES, EXECUTE, SHOW VIEW ON shop.* TO '$1'@'%';
GRANT SELECT, LOCK TABLES, EXECUTE, SHOW VIEW ON external_mock.* TO '$1'@'%';
SQL
}

{
  echo "CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
  echo "CREATE DATABASE external_mock CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
  ddl nova_admin "$PW_NOVA_ADMIN"
  ddl nova_migrator "$PW_NOVA_MIGRATOR"
  for u in $APP_USERS; do
    v="PW_${u^^}"
    crud "$u" "${!v}"
  done
  read_only nova_exporter "$PW_NOVA_EXPORTER"
} | sql
