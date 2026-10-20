# mysqld_exporter 계정 — 관측 스택(monitoring/lgtm)의 mysqld-exporter 컨테이너가 이 DB 의 지표를 긁는다 (NV-431)
#
# NCP 사용자 권한은 READ/CRUD/DDL 세 단계뿐이라 가장 좁은 READ 로 만든다. 2026-10-19 SHOW GRANTS 로 본 READ 의 실제 권한:
#   전역 PROCESS · SHOW DATABASES · REPLICATION CLIENT, mysql · sys · performance_schema 와 각 DB 의 SELECT(+ LOCK TABLES · EXECUTE · SHOW VIEW)
# 비밀은 obs 실행 역할만 읽고, exporter 컨테이너 하나에만 들어간다.
#
# 서비스 계정(main.tf 의 ncloud_mysql_users.this)과 리소스를 나눈다. 그 목록은 RequiresReplace 라 항목을 하나 더하면
# 모든 서비스 계정을 지웠다 다시 만든다. 이 리소스는 자기 목록의 계정만 읽고 지운다(provider 가 이름으로 거른다).

resource "ncloud_mysql_users" "exporter" {
  mysql_instance_no = ncloud_mysql.this.id

  mysql_user_list = [{
    name                   = "nova_exporter"
    password               = random_password.user["exporter"].result
    host_ip                = "%"
    authority              = "READ"
    is_system_table_access = true # 시스템 테이블(상태 · 변수) 조회. 기본값과 같지만 의도를 적는다
  }]

  lifecycle {
    prevent_destroy = true # RDS 이전이 끝날 때까지 (main.tf)
  }
}

# 운영용 비밀과 같은 자리(db/<키>). 서비스 공용 실행 역할은 db/app/* 만 읽으므로 이 비밀은 못 읽는다
resource "aws_secretsmanager_secret" "exporter" {
  name                    = "${local.name_prefix}/db/exporter"
  description             = "NCP MySQL read-only account for mysqld_exporter (observability stack only)"
  recovery_window_in_days = 7

  tags = { Service = "obs" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "exporter" {
  secret_id = aws_secretsmanager_secret.exporter.id
  secret_string_wo = jsonencode({
    username = "nova_exporter"
    password = random_password.user["exporter"].result
    host     = local.db_host
    port     = tostring(var.port)
  })
  secret_string_wo_version = var.password_version * 1000 + (local.db_host == "" ? 0 : 1)
}
