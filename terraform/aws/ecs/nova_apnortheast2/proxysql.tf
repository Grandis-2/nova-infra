# ─────────────────────────────────────────────────────────────
# ProxySQL — RDS 이전(NCP → RDS) 기간에만 앱과 DB 사이에 둔다
#
#   앱 → 내부 NLB 3306 → ProxySQL 2대(온디맨드, 2a · 2c) → NCP(NAT) · RDS
#
# NCP 와 RDS 를 같은 호스트그룹에 두고 상태(ONLINE · OFFLINE_SOFT · OFFLINE_HARD)만 바꿔 쓰기 대상을 옮긴다.
# 바꾸는 일은 런북(scripts/db-migration 의 60-cutover · 70-rollback)이 관리 포트(6032)로 한다. Terraform 은 처음 상태만 정한다.
#
# 처음 상태는 SSM 의 쓰기 대상(rds 스택 writer_parameter, ncp | rds)이다. ECS 가 태스크를 띄울 때 읽어 설정 컨테이너에 넣으므로
# 태스크가 다시 떠도 런북이 마지막으로 정한 DB 로 간다. 값을 못 읽으면 태스크가 뜨지 않는다(어느 서버도 ONLINE 이 아닌 채로 받지 않는다).
# 설정 파일은 태스크마다 새로 만들고 --initial 로 읽는다. 컨테이너만 다시 띄우지 않는다(재시작 정책 없음, 태스크째 교체).
#
# 이전 기간에는 이 태스크 정의를 바꾸지 않는다. 바꾸면 롤링 배포로 두 노드가 새로 떠서 연결이 한 번 끊긴다.
#
# 순서: proxysql_enabled(NLB · 서비스 생성, 앱은 아직 NCP 직결) → 점검 · 리허설 → db_via_proxysql(앱 주소를 NLB 로)
#       → 전환 → db_via_proxysql = false(앱이 RDS 직결) → proxysql_enabled = false
# ─────────────────────────────────────────────────────────────

locals {
  proxysql_name      = "${local.name_prefix}-proxysql"
  proxysql_hostgroup = 10
  proxysql_port      = 3306
  proxysql_admin     = 6032

  # 런북 · 설정 컨테이너가 쓰는 rds 스택 출력. db_state = "rds" 일 때만 있다
  db_migration = var.db_state == "rds" ? data.terraform_remote_state.database.outputs : null

  # ProxySQL 은 앱 계정 그대로 뒷단에 붙는다. DB 계정 이름은 ncp-database 스택과 같다(하이픈 → 밑줄)
  proxysql_users = [
    for k, v in local.services : {
      username = replace(v.name, "-", "_")
      env      = "PW_${upper(replace(v.name, "-", "_"))}"
      secret   = local.db_secret_arns[k]
    } if v.db != null
  ]

  proxysql_secrets = try(data.terraform_remote_state.secrets.outputs.db_migration_secret_arns, {})
}

# 런북이 쓴 지금의 쓰기 대상(ncp | rds)
data "aws_ssm_parameter" "writer" {
  count = var.db_state == "rds" ? 1 : 0
  name  = local.db_migration.writer_parameter.name
}

resource "terraform_data" "proxysql_check" {
  lifecycle {
    precondition {
      condition     = !var.proxysql_enabled || var.db_state == "rds"
      error_message = "ProxySQL 은 rds 스택 출력(ncp_address · rds_address · writer_parameter)을 읽는다. db_state = \"rds\" 와 함께 켠다."
    }
    precondition {
      condition     = !var.db_via_proxysql || var.proxysql_enabled
      error_message = "db_via_proxysql 은 proxysql_enabled 가 켜져 있어야 한다(앱이 붙을 NLB 가 없다)."
    }
    precondition {
      condition     = !var.proxysql_enabled || alltrue([for k in ["proxysql-admin", "proxysql-monitor"] : contains(keys(local.proxysql_secrets), k)])
      error_message = "secretsmanager 스택의 db/proxysql-admin · db/proxysql-monitor 가 아직 없다. secretsmanager 를 먼저 apply 한다."
    }
    precondition {
      # 앱이 ProxySQL 없이 DB 에 바로 붙을 때의 주소는 rds 스택의 primary 다. 런북이 쓴 실제 쓰기 대상과 다르면 두 DB 에
      # 쓰기가 갈린다(전환 뒤 rds 의 primary 를 바꾸기 전에 db_via_proxysql 을 끌 때)
      condition     = var.db_state != "rds" || var.db_via_proxysql || local.db_migration.primary == data.aws_ssm_parameter.writer[0].insecure_value
      error_message = "앱이 DB 에 바로 붙는데 rds 스택의 primary 가 런북의 쓰기 대상과 다르다. rds 스택의 primary 를 먼저 맞춰 apply 한다."
    }
    precondition {
      condition     = !var.proxysql_enabled || try(data.terraform_remote_state.iam.outputs.proxysql_execution_role_arn, "") != ""
      error_message = "iam 스택의 ProxySQL 실행 역할이 없다. iam 의 db_migration = true 를 먼저 apply 한다."
    }
  }
}

resource "aws_cloudwatch_log_group" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  name              = "/ecs/${local.proxysql_name}"
  retention_in_days = var.log_retention_days

  tags = { Name = local.proxysql_name }
}

resource "aws_ecs_task_definition" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  family                   = local.proxysql_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.terraform_remote_state.iam.outputs.proxysql_execution_role_arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  # 설정 파일을 두 컨테이너가 나눠 쓴다(태스크 수명 동안만 있는 볼륨)
  volume {
    name = "config"
  }

  container_definitions = jsonencode([
    {
      name       = "config-init"
      image      = var.proxysql_image
      essential  = false
      entryPoint = ["/bin/sh", "-c"]
      command = [templatefile("${path.module}/templates/proxysql_config.sh.tftpl", {
        admin_port             = local.proxysql_admin
        server_version         = local.db_migration.engine_version
        hostgroup              = local.proxysql_hostgroup
        server_max_connections = 500
        ncp_address            = local.db_migration.ncp_address
        ncp_port               = 3306
        rds_address            = local.db_migration.rds_address
        rds_port               = local.db_migration.rds_port
        users                  = local.proxysql_users
      })]
      secrets = concat(
        [
          { name = "WRITER", valueFrom = local.db_migration.writer_parameter.arn },
          { name = "PROXYSQL_ADMIN_PASSWORD", valueFrom = "${local.proxysql_secrets["proxysql-admin"]}:password::" },
          { name = "PROXYSQL_MON_PASSWORD", valueFrom = "${local.proxysql_secrets["proxysql-monitor"]}:password::" },
        ],
        [for u in local.proxysql_users : { name = u.env, valueFrom = "${u.secret}:password::" }],
      )
      mountPoints = [{ sourceVolume = "config", containerPath = "/config", readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.proxysql[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "config-init"
        }
      }
    },
    {
      name      = "proxysql"
      image     = var.proxysql_image
      essential = true
      command   = ["proxysql", "-f", "--idle-threads", "--initial", "-c", "/config/proxysql.cnf", "-D", "/var/lib/proxysql"] # 이미지 CMD(로컬 시험)와 같게 --idle-threads
      portMappings = [
        { containerPort = local.proxysql_port, protocol = "tcp", name = "mysql" },
        { containerPort = local.proxysql_admin, protocol = "tcp", name = "admin" },
      ]
      mountPoints = [{ sourceVolume = "config", containerPath = "/config", readOnly = true }]
      dependsOn   = [{ containerName = "config-init", condition = "SUCCESS" }]
      ulimits     = [{ name = "nofile", softLimit = 65535, hardLimit = 65535 }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.proxysql[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "proxysql"
        }
      }
    },
  ])

  tags = { Name = local.proxysql_name }

  depends_on = [terraform_data.proxysql_check]
}

# ── 내부 NLB ─────────────────────────────────────────────────
# NLB 는 TLS 를 풀지 않고 넘긴다(앱 ↔ ProxySQL 은 sslMode=REQUIRED 그대로). 유휴 TCP 연결은 350초에 끊는데,
# Hikari keepalive(2분)가 그보다 짧아 풀 연결이 끊기지 않는다
resource "aws_lb" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  name                             = local.proxysql_name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = local.app_subnets
  security_groups                  = [data.terraform_remote_state.security.outputs.proxysql_nlb_security_group_id]
  enable_cross_zone_load_balancing = true # 한 AZ 의 노드가 빠져도 남은 노드로 보낸다

  tags = { Name = local.proxysql_name }
}

resource "aws_lb_target_group" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  name        = local.proxysql_name
  port        = local.proxysql_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = local.vpc_id

  preserve_client_ip = "false" # 출발지를 NLB 로 바꾼다. ProxySQL SG 는 NLB SG 만 믿는다(기본값이지만 바뀌지 않게 적어 둔다)
  # 교체된 태스크의 옛 IP 가 draining 으로 남는 동안 런북의 노드 대조가 어긋나 멈춘다. 기본 300초를 줄인다
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = local.proxysql_name }
}

resource "aws_lb_listener" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  load_balancer_arn = aws_lb.proxysql[0].arn
  port              = local.proxysql_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxysql[0].arn
  }
}

resource "aws_ecs_service" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  name            = local.proxysql_name
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.proxysql[0].arn
  desired_count   = 2

  propagate_tags                = "SERVICE"
  availability_zone_rebalancing = "ENABLED" # 두 AZ 에 하나씩

  # 전환 중 회수되면 안 되므로 온디맨드만 쓴다
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 0
    weight            = 1
  }

  network_configuration {
    subnets          = local.app_subnets
    security_groups  = [data.terraform_remote_state.security.outputs.proxysql_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.proxysql[0].arn
    container_name   = "proxysql"
    container_port   = local.proxysql_port
  }

  health_check_grace_period_seconds = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  wait_for_steady_state = false

  depends_on = [aws_lb_listener.proxysql]

  tags = { Name = local.proxysql_name }
}

# 런북이 노드(태스크 IP:6032)를 찾고 NLB 대상과 대조할 때 읽는다. 비밀이 아니므로 plan 에서 보이게 둔다
resource "aws_ssm_parameter" "proxysql" {
  count = var.proxysql_enabled ? 1 : 0

  name = "/${local.name_prefix}/db-migration/proxysql"
  type = "String"
  insecure_value = jsonencode({
    cluster        = aws_ecs_cluster.this.name
    service        = aws_ecs_service.proxysql[0].name
    targetGroupArn = aws_lb_target_group.proxysql[0].arn
    nlbAddress     = aws_lb.proxysql[0].dns_name
    adminPort      = local.proxysql_admin
    hostgroup      = local.proxysql_hostgroup
    nodes          = 2
    servers = {
      ncp = local.db_migration.ncp_address
      rds = local.db_migration.rds_address
    }
  })

  tags = { Name = local.proxysql_name }
}
