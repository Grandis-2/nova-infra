# NCP Cloud DB for MySQL. 비용 때문에 RDS 대신 쓴다.
# AWS 와 사설 연결이 없어 ECS → NAT(고정 IP) → 인터넷 → NCP Public 도메인 경로로 접속하고,
# ACG 는 NAT 고정 IP 만 허용한다.
#
# Public 도메인은 Terraform 으로 켤 수 없다. apply 후 콘솔(DB 관리 → Public 도메인 관리)에서 켜고
# 다시 apply 해야 db_address 가 채워진다. 그 전까지 ecs 스택 plan 은 실패한다.
#
# NCP provider 는 DB 비밀번호를 인자로 받아 상태 파일에 평문으로 남는다. 상태 버킷 접근을 좁게 유지한다.
# NCP 사용자 권한은 READ/CRUD/DDL 뿐이라 테이블 단위 권한은 관리자 계정으로 직접 준다.

locals {
  nat_ips = data.terraform_remote_state.vpc.outputs.nat_public_ips

  # DB 를 쓰는 서비스. 계정 이름은 서비스 이름의 하이픈을 밑줄로 바꾼 것 (NCP 제한 4~16자)
  db_services = { for k, v in local.services : k => v if v.db != null }
}

# ── 네트워크 (NCP) ───────────────────────────────────────────
# Public 도메인은 Public 서브넷의 DB 서버에만 붙일 수 있다
resource "ncloud_vpc" "this" {
  name            = "${local.name_prefix}-db"
  ipv4_cidr_block = var.vpc_cidr
}

resource "ncloud_subnet" "db" {
  name           = "${local.name_prefix}-db-public"
  vpc_no         = ncloud_vpc.this.vpc_no
  subnet         = cidrsubnet(var.vpc_cidr, 8, 1)
  zone           = var.zone
  network_acl_no = ncloud_vpc.this.default_network_acl_no
  subnet_type    = "PUBLIC"
  usage_type     = "GEN"
}

# ── 계정 비밀번호 ────────────────────────────────────────────
# NCP 규칙: 8~20자, 영문·숫자·특수문자 포함. ` & + \ " ' / 공백은 쓸 수 없다
resource "random_password" "user" {
  for_each = merge(local.db_services, { admin = {}, migrator = {} })

  length           = 20
  special          = true
  override_special = "!#$%*-_=?@^~"
  min_special      = 1
  min_numeric      = 1
  min_lower        = 1
  min_upper        = 1

  keepers = { version = var.password_version }
}

# ── DB ───────────────────────────────────────────────────────
# NCP 목록을 조회해 조건에 맞는 첫 번째 이미지 · 사양을 쓴다 (코드를 손으로 적지 않는다).
#   이미지: G3 · MySQL 8.4.x
#   사양  : STAND · vCPU 2 · 메모리 8GB · AMD 아님 (AMD 모델은 이름에 "(AMD)", 코드에 ".AMD." 가 붙는다)
# provider(ncloud 4.0.7)의 filter 는 여러 개면 OR 로 합쳐지고 숫자 필드를 맞추지 못한다.
# 그래서 provider filter 는 문자열 하나만 쓰고 나머지 조건은 locals 에서 건다.
data "ncloud_mysql_image_products" "this" {
  filter {
    name   = "generation_code"
    values = [var.generation]
  }
}

locals {
  mysql_image = try([for i in data.ncloud_mysql_image_products.this.image_product_list : i
    if startswith(i.engine_version_code, "${var.engine_version_prefix}.")
  ][0], null)
}

data "ncloud_mysql_products" "this" {
  image_product_code = try(local.mysql_image.product_code, "")

  filter {
    name   = "product_type"
    values = [var.server_type]
  }

  lifecycle {
    precondition {
      condition     = local.mysql_image != null
      error_message = "${var.generation} 세대에 MySQL ${var.engine_version_prefix}.x 이미지가 없습니다. 이미지 목록: ${join(", ", [for i in data.ncloud_mysql_image_products.this.image_product_list : "${i.product_name} (${i.engine_version_code})"])}"
    }
  }
}

locals {
  mysql_product = try([for p in data.ncloud_mysql_products.this.product_list : p
    if p.product_name == "vCPU ${var.vcpu}EA, Memory ${var.memory_gb}GB" && !strcontains(p.product_code, ".AMD.")
  ][0], null)
}

resource "ncloud_mysql" "this" {
  service_name       = "${local.name_prefix}-mysql"
  server_name_prefix = "${var.product}-db"
  subnet_no          = ncloud_subnet.db.id

  image_product_code  = local.mysql_image.product_code
  product_code        = try(local.mysql_product.product_code, null) # 없으면 아래 precondition 이 사양 목록을 보여 준다
  engine_version_code = local.mysql_image.engine_version_code
  port                = var.port

  is_ha                 = var.is_ha # HA 는 서버 2대(요금 2배)
  is_backup             = true
  is_automatic_backup   = true
  is_storage_encryption = var.is_ha # 저장 암호화는 HA 에서만 켤 수 있다

  # 관리자 계정. 서비스 태스크에는 주지 않는다
  user_name     = "nova_admin"
  user_password = random_password.user["admin"].result
  host_ip       = "%" # 네트워크 제한은 ACG 가 맡는다
  database_name = "shop"

  lifecycle {
    precondition {
      condition     = local.mysql_product != null
      error_message = "${var.generation} ${var.server_type} vCPU ${var.vcpu} · 메모리 ${var.memory_gb}GB (AMD 아님) 사양이 없습니다. 사양 목록: ${join(", ", [for p in data.ncloud_mysql_products.this.product_list : "${p.product_name} (${p.product_code})"])}"
    }
    precondition {
      condition     = length(local.nat_ips) > 0
      error_message = "vpc 스택의 nat_public_ips 가 비어 있다. 허용 IP 없이 DB 를 만들 수 없으니 vpc 스택을 먼저 apply 한다."
    }
  }
}

resource "ncloud_mysql_databases" "extra" {
  mysql_instance_no = ncloud_mysql.this.id

  mysql_database_list = [
    { name = "external_mock" }, # mock 소유, batch 는 읽기만
  ]
}

resource "ncloud_mysql_users" "this" {
  mysql_instance_no = ncloud_mysql.this.id

  mysql_user_list = concat(
    [for k, v in local.db_services : {
      name      = replace(v.name, "-", "_")
      password  = random_password.user[k].result
      host_ip   = "%"
      authority = "CRUD"
    }],
    # Flyway 마이그레이션 전용
    [{
      name      = "nova_migrator"
      password  = random_password.user["migrator"].result
      host_ip   = "%"
      authority = "DDL"
    }],
  )
}

# ── 접근 제어 (ACG) ──────────────────────────────────────────
# DB 가 만든 ACG 에 NAT 고정 IP 만 DB 포트로 허용한다.
# 규칙 리소스가 여러 개면 서로 덮어쓰므로 이 ACG 는 이 리소스로만 관리한다.
resource "ncloud_access_control_group_rule" "db" {
  access_control_group_no = ncloud_mysql.this.access_control_group_no_list[0]

  inbound = [for ip in local.nat_ips : {
    protocol                       = "TCP"
    ip_block                       = "${ip}/32"
    port_range                     = tostring(var.port)
    description                    = "AWS NAT ${ip}"
    source_access_control_group_no = null
  }]
}

# ── Secrets Manager ──────────────────────────────────────────
locals {
  # 콘솔에서 Public 도메인을 켜기 전에는 빈 문자열
  db_host = try(one(compact([for s in ncloud_mysql.this.mysql_server_list : s.public_domain if s.public_domain != null])), "")
}

resource "aws_secretsmanager_secret" "service" {
  for_each = local.db_services

  name                    = "${local.name_prefix}/db/app/${each.value.name}"
  description             = "DB account for the ${each.value.name} service (NCP MySQL)"
  recovery_window_in_days = 7

  tags = { Service = each.value.name }
}

resource "aws_secretsmanager_secret_version" "service" {
  for_each = local.db_services

  secret_id = aws_secretsmanager_secret.service[each.key].id
  secret_string_wo = jsonencode({
    username = replace(each.value.name, "-", "_")
    password = random_password.user[each.key].result
    host     = local.db_host
    port     = tostring(var.port)
    dbname   = each.value.db
  })
  # host 가 나중에 채워지므로 버전에 반영해, 도메인이 생기면 시크릿을 다시 쓴다
  secret_string_wo_version = var.password_version * 1000 + (local.db_host == "" ? 0 : 1)
}

# 마이그레이션, 운영용. 서비스 태스크에는 주지 않는다
resource "aws_secretsmanager_secret" "ops" {
  for_each = toset(["migrator", "admin"])

  name                    = "${local.name_prefix}/db/${each.key}"
  description             = "NCP MySQL ${each.key} account (operators and migrations only)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "ops" {
  for_each = toset(["migrator", "admin"])

  secret_id = aws_secretsmanager_secret.ops[each.key].id
  secret_string_wo = jsonencode({
    username = each.key == "admin" ? "nova_admin" : "nova_migrator"
    password = random_password.user[each.key].result
    host     = local.db_host
    port     = tostring(var.port)
    dbname   = "shop"
  })
  secret_string_wo_version = var.password_version * 1000 + (local.db_host == "" ? 0 : 1)
}
