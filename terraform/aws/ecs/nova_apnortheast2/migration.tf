# ─────────────────────────────────────────────────────────────
# 마이그레이션 태스크 — Flyway 로 shop 스키마를 올린다 (be flyway-project)
#
# be release 가 서비스를 배포하기 전에 RunTask 로 한 번 띄우고 끝나기를 기다린다 (be .github/scripts/ecs-migrate.sh).
# DB(NCP)는 NAT 고정 IP 만 받아 GitHub 러너에서는 닿지 않으므로 클러스터 안에서 돈다. 실패하면 release 는 배포하지 않는다.
# 서비스가 아니라 application/ 에 두지 않는다. 이미지는 nova/migration:latest 이고 release 가 띄우기 직전에 올린다.
# ─────────────────────────────────────────────────────────────

locals {
  migration_name      = "${local.name_prefix}-migration"
  migration_container = "flyway" # 컨테이너 이름이자 로그 스트림 접두사. 스트림은 flyway/flyway/<태스크 ID>
  migrator_secret_arn = data.terraform_remote_state.database.outputs.ops_secret_arns["migrator"]

  # Flyway 이미지(redgate/flyway)의 JDBC 드라이버는 MariaDB 2.7 이라 서비스의 sslMode 를 모른다 — 넣어도 TLS 를 켜지 않아
  # 서버의 인증 캐시가 비면 caching_sha2 인증에서 실패하고, 차 있으면 평문으로 붙는다. 같은 뜻의 그 드라이버 옵션으로 옮긴다
  flyway_ssl_params = {
    REQUIRED = "useSsl=true&trustServerCertificate=true" # 암호화, 인증서는 확인하지 않음
  }
}

resource "aws_cloudwatch_log_group" "migration" {
  name              = "/ecs/${local.migration_name}"
  retention_in_days = var.log_retention_days

  tags = { Name = local.migration_name }
}

resource "aws_ecs_task_definition" "migration" {
  family                   = local.migration_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.terraform_remote_state.iam.outputs.migration_execution_role_arn

  # redgate/flyway 는 amd64 이미지뿐이다 (서비스의 cpu_architecture 와 상관없이)
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = local.migration_container
    image     = "${local.repository_urls["migration"]}:latest"
    essential = true

    environment = [
      { name = "FLYWAY_URL", value = "jdbc:mysql://${local.db_address}:${local.db_port}/shop?${lookup(local.flyway_ssl_params, var.db_ssl_mode, "")}" },
    ]
    secrets = [
      { name = "FLYWAY_USER", valueFrom = "${local.migrator_secret_arn}:username::" },
      { name = "FLYWAY_PASSWORD", valueFrom = "${local.migrator_secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migration.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.migration_container
      }
    }
  }])

  tags = { Name = local.migration_name }

  lifecycle {
    precondition {
      condition     = contains(keys(local.flyway_ssl_params), var.db_ssl_mode)
      error_message = "db_ssl_mode '${var.db_ssl_mode}' 를 Flyway(MariaDB 드라이버) 접속 옵션으로 옮긴 값이 없습니다. migration.tf 의 flyway_ssl_params 에 더하세요."
    }
    # 태스크 SG 는 3306 만 내보낸다 (securitygroup 스택 migration.tf). 포트가 다르면 서비스는 뜨고 마이그레이션만 접속 시간 초과로 실패한다
    precondition {
      condition     = tonumber(local.db_port) == 3306
      error_message = "DB 포트가 ${local.db_port} 입니다. 이 조건의 3306 과 securitygroup 스택 migration.tf 의 3306 나가는 규칙을 함께 바꾸세요."
    }
  }
}

# release 가 RunTask 에 넘길 값. 서브넷 · SG · 용량 공급자는 태스크 정의에 담을 수 없어 여기 적는다 (be .github/scripts/ecs-migrate.sh 가 읽는다).
# 비밀이 아니므로 plan 에서 보이게 insecure_value 로 둔다.
# 용량은 서비스처럼 Fargate Spot 이다. 회수되면 태스크가 실패하고 release 는 배포하지 않는다 (be flyway-project/README.md 의 실패 복구)
resource "aws_ssm_parameter" "migration" {
  name = "/${local.name_prefix}/migration/run-task"
  type = "String"
  insecure_value = jsonencode({
    cluster         = aws_ecs_cluster.this.name
    taskDefinition  = aws_ecs_task_definition.migration.family
    container       = local.migration_container
    logGroup        = aws_cloudwatch_log_group.migration.name
    logStreamPrefix = local.migration_container
    subnets         = local.app_subnets
    securityGroups  = [data.terraform_remote_state.security.outputs.migration_security_group_id]
    capacityProviderStrategy = [
      { capacityProvider = "FARGATE_SPOT", weight = 1 },
    ]
  })

  tags = { Name = local.migration_name }
}

# ── mock 마이그레이션 (NV-524) ─────────────────────────────────
# mock 저장소 release 가 external_mock 스키마를 올린다. 이미지는 nova/mock-migration:latest(mock db/Dockerfile)이고
# mock 전용 배포 역할(iam 스택 github_deploy_mock.tf)이 띄운다. be 것과 다른 점은 이름 · 이미지 · 접속 DB 뿐이다
locals {
  mock_migration_name = "${local.name_prefix}-mock-migration"
}

resource "aws_cloudwatch_log_group" "mock_migration" {
  name              = "/ecs/${local.mock_migration_name}"
  retention_in_days = var.log_retention_days

  tags = { Name = local.mock_migration_name }
}

resource "aws_ecs_task_definition" "mock_migration" {
  family                   = local.mock_migration_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.terraform_remote_state.iam.outputs.migration_execution_role_arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = local.migration_container
    image     = "${local.repository_urls["mock-migration"]}:latest"
    essential = true

    environment = [
      { name = "FLYWAY_URL", value = "jdbc:mysql://${local.db_address}:${local.db_port}/external_mock?${lookup(local.flyway_ssl_params, var.db_ssl_mode, "")}" },
    ]
    secrets = [
      { name = "FLYWAY_USER", valueFrom = "${local.migrator_secret_arn}:username::" },
      { name = "FLYWAY_PASSWORD", valueFrom = "${local.migrator_secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mock_migration.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = local.migration_container
      }
    }
  }])

  tags = { Name = local.mock_migration_name }

  # 접속 옵션 · 포트 검사는 be 마이그레이션 태스크(aws_ecs_task_definition.migration)의 precondition 이 같은 값으로 한다
}

# mock release 가 RunTask 에 넘길 값 (mock .github 의 마이그레이션 스크립트가 이 이름으로 읽는다)
resource "aws_ssm_parameter" "mock_migration" {
  name = "/${local.name_prefix}/mock-migration/run-task"
  type = "String"
  insecure_value = jsonencode({
    cluster         = aws_ecs_cluster.this.name
    taskDefinition  = aws_ecs_task_definition.mock_migration.family
    container       = local.migration_container
    logGroup        = aws_cloudwatch_log_group.mock_migration.name
    logStreamPrefix = local.migration_container
    subnets         = local.app_subnets
    securityGroups  = [data.terraform_remote_state.security.outputs.migration_security_group_id]
    capacityProviderStrategy = [
      { capacityProvider = "FARGATE_SPOT", weight = 1 },
    ]
  })

  tags = { Name = local.mock_migration_name }
}
