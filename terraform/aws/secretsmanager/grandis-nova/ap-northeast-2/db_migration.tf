# RDS 이전(NCP → RDS) 동안만 쓰는 DB 계정 비밀. 계정은 런북(scripts/db-migration)이 이 값으로 만든다.
#
#   db/replication       NCP 의 repl_rds(REPLICATION SLAVE · CLIENT). RDS 가 NCP binlog 를 받을 때 쓴다
#   db/proxysql-admin    ProxySQL 관리 포트(6032)의 radmin. 런북(bastion)과 ProxySQL 설정 컨테이너가 읽는다
#   db/proxysql-monitor  ProxySQL 이 NCP · RDS 상태를 볼 때 쓰는 proxysql_mon(접속만). 두 DB 에 같은 값으로 만든다
#   db/dump              NCP 의 dump_rds. RELOAD · FLUSH_TABLES 없이 덤프해 전역 읽기 잠금을 피한다(10-ncp-users.sh 머리말)
#   db/rehearsal         리허설 프로브 계정 rehearsal_probe. ProxySQL 리허설 그룹과 리허설 DB 두 곳에만 만든다(50-rehearsal-proxysql.sh)
#
# db/app/* 가 아니라서 서비스 공용 실행 역할은 읽지 못한다(iam 스택 execution.tf).
# 문자는 영문 · 숫자와 - _ . ~ 만 쓴다. ProxySQL 설정 문자열(" \ 불가) · admin_credentials(: ; 불가) ·
# mysql 옵션 파일(# 주석, \ 이스케이프) · NCP 비밀번호 규칙(` & + \ " ' / 공백 불가)에 모두 걸리지 않는 문자다.
# generated.tf 와 같이 ephemeral 로 만들어 쓰기 전용으로 넣는다. secret_versions["db/<이름>"] 을 올리면 새 값이 되지만,
# 이미 만든 DB 계정은 따라가지 않으므로 이전 기간에는 올리지 않는다. 전환 뒤 계정과 함께 지운다.

locals {
  db_migration_secrets = {
    replication        = "repl_rds"
    "proxysql-admin"   = "radmin"
    "proxysql-monitor" = "proxysql_mon"
    dump               = "dump_rds"
    rehearsal          = "rehearsal_probe"
  }
}

ephemeral "random_password" "db_migration" {
  for_each = local.db_migration_secrets

  length           = 32
  special          = true
  override_special = "-_.~"
  min_special      = 1
  min_numeric      = 1
  min_lower        = 1
  min_upper        = 1
}

resource "aws_secretsmanager_secret" "db_migration" {
  for_each = local.db_migration_secrets

  name                    = "${local.name_prefix}/db/${each.key}"
  description             = "RDS migration only: ${each.value} account (runbook, ProxySQL)"
  recovery_window_in_days = 7

  tags = { Service = "db-migration" }
}

resource "aws_secretsmanager_secret_version" "db_migration" {
  for_each = local.db_migration_secrets

  secret_id = aws_secretsmanager_secret.db_migration[each.key].id
  secret_string_wo = jsonencode({
    username = each.value
    password = ephemeral.random_password.db_migration[each.key].result
  })
  secret_string_wo_version = local.version_of["db/${each.key}"]
}
