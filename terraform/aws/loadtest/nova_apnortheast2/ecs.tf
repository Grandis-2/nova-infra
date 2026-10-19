# 클러스터 · 작업 정의 · 로그 그룹. 서비스는 없다.
# nova-loadtest 워크플로가 컨트롤러를 RunTask 로 띄우고, 컨트롤러가 발급기와 k6 N 대를 띄운다. 평소에는 0대다.
# 이미지는 마이그레이션처럼 :latest 다(RunTask 는 이미지를 바꾸지 못한다).

locals {
  # 작업 정의 키(실행 파라미터 tasks.<키>) -> 컨테이너 이름(로그 스트림 접두사) · 크기 · 역할
  tasks = {
    controller  = { container = "controller", cpu = 256, memory = 512, task_role = "controller", execution_role = "execution" }
    k6          = { container = "k6", cpu = 4096, memory = 8192, task_role = "k6", execution_role = "execution" }
    tokenMinter = { container = "token-minter", cpu = 512, memory = 1024, task_role = "minter", execution_role = "minter-execution" }
  }

  # 발급기가 토큰 헤더 · 클레임에 넣는 값. member 가 검증에 쓰는 설정을 그대로 읽는다.
  # kid 는 개인키에서 계산하는 값이 아니라 이 설정값이고, 검증 서비스는 kid 로 공개키를 고른다. 어긋나면 모든 요청이 401 이다
  member_jwt = yamldecode(file("${local.application_dir}/member/application.yml")).jwt

  # 작업 정의마다 더하는 컨테이너 설정 (컨트롤러는 없다. 헤더도 쓰지 않는다)
  container_extra = {
    # 수집 주소(K6_OTEL_HTTP_EXPORTER_ENDPOINT)와 태스크마다 다른 값은 컨트롤러가 RunTask 로 넣는다(관측 실행 파라미터).
    # k6 OTel 출력은 OTel 표준 변수가 아니라 자기 변수를 쓴다. 기본 grpc(4317)는 SG 에 막히므로 http/protobuf. 게이트웨이는 평문 HTTP 다
    k6 = {
      environment = [
        { name = "K6_OTEL_EXPORTER_PROTOCOL", value = "http/protobuf" },
        { name = "K6_OTEL_HTTP_EXPORTER_INSECURE", value = "true" },
        { name = "K6_OTEL_SERVICE_NAME", value = "k6" },
        { name = "K6_OTEL_METRIC_PREFIX", value = "k6_" },
      ]
      secrets = [
        { name = "LOADTEST_HEADER", valueFrom = local.header_secret_arn },
      ]
      # 멈출 때 k6 가 지표를 마저 보내고 요약을 올릴 시간(Fargate 최대 120초)
      stopTimeout = 120
      ulimits     = [{ name = "nofile", softLimit = 65536, hardLimit = 65536 }]
    }
    # 서명키는 PKCS#8 PEM 문자열 하나(JSON 아님)라 비밀 ARN 을 그대로 넣는다
    tokenMinter = {
      environment = [
        { name = "JWT_ISSUER", value = tostring(local.member_jwt.issuer) },
        { name = "JWT_AUDIENCE", value = tostring(local.member_jwt.audience) },
        { name = "JWT_KEY_ID", value = tostring(local.member_jwt["key-id"]) },
      ]
      secrets = [
        { name = "JWT_PRIVATE_KEY", valueFrom = local.jwt_private_key_arn },
      ]
    }
  }
}

resource "aws_ecs_cluster" "loadtest" {
  name = local.loadtest_name

  # k6 에는 실행기 CPU 지표가 없어 Container Insights(작업 정의 패밀리별 CPU)로 본다. 태스크가 없으면 비용도 없다
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = local.loadtest_name }
}

# Spot 은 쓰지 않는다. 시험 중에 회수되면 그 시험 결과를 버려야 하고, 발급기 · 컨트롤러는 작아 아낄 것이 없다
resource "aws_ecs_cluster_capacity_providers" "loadtest" {
  cluster_name       = aws_ecs_cluster.loadtest.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# 스트림은 <컨테이너>/<컨테이너>/<태스크 ID>. -github-run 은 controller/* 만 읽는다
resource "aws_cloudwatch_log_group" "loadtest" {
  name              = "/ecs/${local.loadtest_name}"
  retention_in_days = 7

  tags = { Name = local.loadtest_name }
}

resource "aws_ecs_task_definition" "task" {
  for_each = local.tasks

  family                   = "${local.loadtest_name}-${each.value.container}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  task_role_arn            = aws_iam_role.task[each.value.task_role].arn
  execution_role_arn       = aws_iam_role.execution[each.value.execution_role].arn

  # 서비스와 같은 x86. nova-loadtest 빌드도 linux/amd64 로 만든다. 바꾸면 그쪽 빌드 플랫폼도 같이 바꾼다
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([merge(
    {
      name      = each.value.container
      image     = "${aws_ecr_repository.loadtest[each.value.container].repository_url}:latest"
      essential = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.loadtest.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.value.container
        }
      }
    },
    try(local.container_extra[each.key], {}),
  )])

  tags = { Name = "${local.loadtest_name}-${each.value.container}" }
}
