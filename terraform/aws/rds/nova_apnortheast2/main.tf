# RDS for MySQL — NCP Cloud DB for MySQL 에서 옮겨 오는 운영 DB.
#
# 옮기는 동안(NCP → RDS 복제, ProxySQL 로 전환)과 옮긴 뒤를 이 스택 하나가 맡는다.
#   1. RDS 를 read_only=0 · local_infile=1 로 만든다. 런북이 계정을 만들고 NCP 덤프를 적재한다
#   2. read_only=1 · local_infile=0 으로 바꾸고 복제를 시작한다(런북 40-replication)
#   3. 전환 30분 전 read_only=0, 전환(런북 60-cutover) 뒤 primary = "rds"
# 단계와 순서는 scripts/db-migration/README.md 와 이전 계획을 따른다.
#
# 소비자(ecs · lgtm)는 NCP 스택과 같은 이름의 출력(outputs.tf)을 읽는다. 그래서 database 원격 상태의 key 만
# 이 스택으로 바꾸면 되고, 쓰기 DB 가 어디인지는 primary 하나로 정한다.
#
# 복제를 받으려면 db 서브넷이 NAT 로 나가야 한다(vpc 스택 db_subnet_nat_egress, securitygroup 스택 rds_replication_egress).

locals {
  db_subnet_ids = data.terraform_remote_state.vpc.outputs.db_subnet_ids
  rds_sg_id     = data.terraform_remote_state.security.outputs.rds_security_group_id
  ncp           = data.terraform_remote_state.database.outputs

  # 8.4.11 -> mysql8.4
  family = "mysql${join(".", slice(split(".", var.engine_version), 0, 2))}"

  identifier = "${local.name_prefix}-mysql"
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = local.db_subnet_ids
}

# ── 파라미터 그룹 ───────────────────────────────────────────
# NCP 와 다르게 동작하지 않도록 2026-10-19 G1 점검(00-precheck)에서 읽은 NCP 값에 맞춘다.
# read_only · local_infile 만 단계마다 바꾸므로 인스턴스마다 변수로 둔다.
locals {
  base_parameters = {
    # 복제 받기: 소스(NCP)가 GTID 를 쓰므로 받는 쪽도 켜야 적용된다. 전환 때 GTID 집합으로 따라잡음을 판정한다
    "gtid-mode"                     = { value = "ON", static = true }
    enforce_gtid_consistency        = { value = "ON", static = true }
    binlog_format                   = { value = "ROW", static = false }
    performance_schema              = { value = "1", static = true }
    require_secure_transport        = { value = "1", static = false }
    log_bin_trust_function_creators = { value = var.log_bin_trust_function_creators ? "1" : "0", static = false }

    # NCP 와 같게 (G1)
    lower_case_table_names          = { value = "0", static = true } # 만들 때만 정할 수 있다
    character_set_server            = { value = "utf8mb4", static = false }
    collation_server                = { value = "utf8mb4_0900_ai_ci", static = false }
    sql_mode                        = { value = "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION", static = false } # RDS 기본값은 NO_ENGINE_SUBSTITUTION 뿐이다
    time_zone                       = { value = "Asia/Seoul", static = false }                                 # NCP 는 +09:00. RDS 는 지역 이름만 받는다
    event_scheduler                 = { value = "OFF", static = false }                                        # MySQL 8 기본값은 ON
    sql_require_primary_key         = { value = "1", static = false }
    explicit_defaults_for_timestamp = { value = "1", static = true } # RDS 에서는 정적이다(immediate 를 주면 그룹 변경 apply 가 거절된다)
    transaction_isolation           = { value = "READ-COMMITTED", static = false }
    innodb_lock_wait_timeout        = { value = "61", static = false }
    lock_wait_timeout               = { value = "61", static = false }
    wait_timeout                    = { value = "28880", static = false }
    max_allowed_packet              = { value = "1073741824", static = false }
    max_connections                 = { value = tostring(var.max_connections), static = false }

    # slowquery 로그를 CloudWatch 로 보낸다(enabled_cloudwatch_logs_exports)
    slow_query_log  = { value = "1", static = false }
    long_query_time = { value = tostring(var.long_query_time), static = false }
    log_output      = { value = "FILE", static = false }
  }

  # 복제를 받는 동안만 두 DB 만 받는다(NCP 의 mysql 계정 변경 등은 받지 않는다). 전환 뒤 반영 PR 에서 끈다(값을 빼면 기본값으로 돌아간다)
  replication_parameters = var.replication_filter ? {
    "replicate-wild-do-table" = { value = "shop.%,external_mock.%", static = false }
  } : {}

  parameter_groups = {
    main = { read_only = var.read_only, local_infile = var.local_infile }
  }
}

resource "aws_db_parameter_group" "this" {
  for_each = local.parameter_groups

  # 메이저 버전을 올릴 때 이름이 겹치지 않도록 family 를 넣는다
  name   = each.key == "main" ? "${local.name_prefix}-${replace(local.family, ".", "-")}" : "${local.name_prefix}-${replace(local.family, ".", "-")}-${each.key}"
  family = local.family

  dynamic "parameter" {
    for_each = merge(local.base_parameters, local.replication_parameters)

    content {
      name  = parameter.key
      value = parameter.value.value
      # 정적 값은 재부팅 때 적용된다. 처음 만들 때는 인스턴스가 이 그룹으로 뜨므로 바로 들어간다
      apply_method = parameter.value.static ? "pending-reboot" : "immediate"
    }
  }

  # 단계마다 바꾸는 값. 동적이라 apply 하면 바로 적용된다
  parameter {
    name         = "read_only"
    value        = each.value.read_only ? "1" : "0"
    apply_method = "immediate"
  }

  parameter {
    name         = "local_infile"
    value        = each.value.local_infile ? "1" : "0"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# RDS 가 처음 로그를 보낼 때 보존 기간 없이 만들기 전에 먼저 만든다
resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(var.cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${local.identifier}/${each.value}"
  retention_in_days = var.log_retention_days
}

# ── 인스턴스 ─────────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # 비용 때문에 단일 AZ. 장애 때는 자동 백업(시점 복구)으로 되살린다
  multi_az          = false
  availability_zone = var.availability_zones[0]

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true # AWS 관리 키

  # 마스터 비밀번호는 RDS 가 Secrets Manager 에 만들고 돌린다(상태 파일에 남지 않는다).
  # 이름은 NCP 의 nova_admin 과 겹치지 않게 한다. 앱 · 운영 계정은 런북(20-rds-accounts)이 NCP 와 같은 이름 · 비밀번호로 만든다
  username                    = "nova_master"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [local.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.this["main"].name
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  # backup_retention_period 를 0 과 0 이 아닌 값 사이에서 바꾸면 재부팅된다. 처음부터 켠다(binlog 도 이것으로 켜진다)
  backup_retention_period = var.backup_retention_days
  backup_window           = "16:00-16:30"         # UTC, KST 01:00. 재고 대조(KST 04 · 05시)를 피한다
  maintenance_window      = "sun:18:00-sun:19:00" # UTC, KST 월 03:00
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = false # 8.4.11 로 고정한다. NCP 와 같은 버전에서 옮긴다
  apply_immediately          = false

  enabled_cloudwatch_logs_exports = var.cloudwatch_logs_exports

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.identifier}-final"

  tags = { Name = local.identifier }

  depends_on = [aws_cloudwatch_log_group.rds]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.primary != "rds" || !var.read_only
      error_message = "primary = \"rds\" 인데 read_only = true 다. 쓰기 DB 는 read_only 를 끈다."
    }
  }
}
