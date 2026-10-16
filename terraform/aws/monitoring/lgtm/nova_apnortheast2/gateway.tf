# ─────────────────────────────────────────────────────────────
# OTel 게이트웨이 (NV-543) — 앱의 OTLP 를 받는 Collector 를 obs 태스크에서 떼어 별도 서비스로 둔다.
#
#   앱 ──OTLP──▶ otel-gateway.<네임스페이스>:4318 · otel-gateway-grpc.<네임스페이스>:4317 (Service Connect)
#     ▶ 게이트웨이(Fargate, 롤링 배포): 마스킹 · 리소스 허용 목록 · tail sampling · span metrics · 서비스 그래프
#     ▶ obs 태스크의 loki:3100 · tempo-otlp:14317 · mimir:9009 (Service Connect)
#
#   ECS 밖의 송신자(엣지 로그 Lambda)는 otel-ingest.<네임스페이스>:4318 로 보낸다. Service Connect 이름은 ECS 서비스
#   태스크 안에서만 풀리므로, 같은 네임스페이스에 태스크 IP 를 가리키는 DNS A 레코드를 따로 둔다.
#
#   obs 는 한 호스트의 디렉터리를 써서 옛 태스크를 내린 뒤 새 태스크를 띄운다. 그동안 게이트웨이는 계속 받고,
#   보내지 못한 데이터는 메모리 전송 큐에 쌓았다가 최대 15분 동안 다시 보낸다(gateway/collector.yaml).
#   게이트웨이 자신은 롤링 배포라 새 태스크가 뜬 뒤 옛 태스크가 내려간다. 겹치는 1~2분은 한 트레이스의 스팬이
#   두 태스크로 나뉘어 tail sampling 결정이 어긋날 수 있다(받아들인다).
#
#   관측 클러스터(nova-prod-observability)에서 돈다. 같은 Service Connect 네임스페이스라 앱 클러스터의 앱이 그대로 이름으로 보낸다.
#   클러스터를 바꾸면 서비스를 지우고 다시 만든다(그동안 수집이 멈추고, 앱 태스크를 다시 띄워야 이름이 풀릴 수 있다).
#
#   설정은 파일 내용을 환경 변수로 넣는다(--config=env:COLLECTOR_CONFIG). S3 내려받기 · 태스크 역할이 필요 없고,
#   설정이 바뀌면 작업 정의가 바뀌어 재배포된다. config/ 밖에 두어 obs 태스크의 설정 해시에 들지 않는다.
#   Spot 은 쓰지 않는다. 회수되면 다음 태스크가 뜰 때까지 모든 수집이 멈춘다.
# ─────────────────────────────────────────────────────────────

locals {
  gateway_name      = "${local.name_prefix}-otel-gateway"
  gateway_namespace = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_name
  # securitygroup 스택(NV-543 1/4)이 먼저 적용돼 있어야 띄운다
  gateway_sg      = try(data.terraform_remote_state.security.outputs.otel_gateway_security_group_id, "")
  gateway_enabled = local.gateway_sg != ""
}

resource "aws_cloudwatch_log_group" "gateway" {
  #checkov:skip=CKV_AWS_158:컨테이너 로그다. 다른 서비스 로그 그룹과 같이 기본 암호화(AWS 관리)를 쓴다
  #checkov:skip=CKV_AWS_338:관측 경로 자체의 로그라 서비스 로그와 같은 보존 기간이면 된다
  name              = "/ecs/${local.gateway_name}"
  retention_in_days = var.obs_log_retention_days
}

resource "aws_ecs_task_definition" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  family                   = local.gateway_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "2048"
  execution_role_arn       = data.terraform_remote_state.iam.outputs.task_execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "otel-collector"
      image     = local.obs_images.otel_collector
      essential = true
      command   = ["--config=env:COLLECTOR_CONFIG"]
      environment = [
        { name = "COLLECTOR_CONFIG", value = file("${path.module}/gateway/collector.yaml") },
        { name = "LOKI_OTLP_ENDPOINT", value = "http://loki.${local.gateway_namespace}:${local.obs_ports.loki_http}/otlp" },
        { name = "TEMPO_OTLP_ENDPOINT", value = "tempo-otlp.${local.gateway_namespace}:${local.obs_ports.tempo_otlp}" },
        { name = "MIMIR_OTLP_ENDPOINT", value = "http://mimir.${local.gateway_namespace}:${local.obs_ports.mimir_http}/otlp" },
      ]
      portMappings = [
        { name = "otlp-grpc", containerPort = local.obs_ports.otlp_grpc, protocol = "tcp", appProtocol = "grpc" },
        { name = "otlp-http", containerPort = local.obs_ports.otlp_http, protocol = "tcp", appProtocol = "http" },
      ]
      readonlyRootFilesystem = true
      stopTimeout            = 30 # 종료 신호를 받으면 큐를 비우며 내려간다
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.gateway.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "otel-collector"
        }
      }
      linuxParameters = local.obs_common.linuxParameters
    },
  ])
}

# Service Connect 와 같은 네임스페이스를 쓰되 이름은 달라야 한다(Service Connect 가 같은 이름의 Cloud Map 서비스를 만든다)
resource "aws_service_discovery_service" "gateway_ingest" {
  count = local.gateway_enabled ? 1 : 0

  name = "otel-ingest"

  dns_config {
    namespace_id   = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"

    # 롤링 배포로 태스크가 바뀌면 새 IP 를 빨리 따라간다
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  # 등록 · 해제는 ECS 가 태스크 상태에 맞춰 한다. 헬스 체크 설정은 두지 않는다
  # (빈 health_check_custom_config 블록은 상태에 남지 않아 plan 마다 교체가 잡힌다)
}

resource "aws_ecs_service" "gateway" {
  count = local.gateway_enabled ? 1 : 0

  name            = local.gateway_name
  cluster         = data.terraform_remote_state.ecs.outputs.observability_cluster_arn
  task_definition = aws_ecs_task_definition.gateway[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = false
  propagate_tags         = "SERVICE"

  # 새 태스크가 뜬 뒤 옛 태스크를 내린다(수신이 끊기지 않는다)
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.terraform_remote_state.vpc.outputs.app_subnet_ids
    security_groups  = [local.gateway_sg]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.gateway_ingest[0].arn
  }

  # 앱은 otel-gateway.<네임스페이스>:4318(HTTP) · otel-gateway-grpc.<네임스페이스>:4317(gRPC) 로 보낸다(ecs 스택 otel.tf).
  # obs 의 loki · tempo-otlp · mimir 별칭으로 내보낸다(이 서비스도 같은 네임스페이스의 클라이언트다)
  service_connect_configuration {
    enabled   = true
    namespace = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_arn

    service {
      port_name      = "otlp-http"
      discovery_name = "otel-gateway"

      client_alias {
        port     = local.obs_ports.otlp_http
        dns_name = "otel-gateway.${local.gateway_namespace}"
      }
    }

    service {
      port_name      = "otlp-grpc"
      discovery_name = "otel-gateway-grpc"

      client_alias {
        port     = local.obs_ports.otlp_grpc
        dns_name = "otel-gateway-grpc.${local.gateway_namespace}"
      }
    }
  }
}

# 게이트웨이가 없으면 모든 수집이 멈춘다. AWS/ECS 의 무료 태스크 수 지표로 보고, 지표가 끊긴 것도 장애로 본다
# (Container Insights 지표를 쓰지 않는다)
resource "aws_cloudwatch_metric_alarm" "gateway_no_task" {
  count = local.gateway_enabled ? 1 : 0

  alarm_name          = "${local.gateway_name}-no-tasks"
  alarm_description   = "OTel gateway has no running task. Logs, traces and metrics from apps are being dropped"
  namespace           = "AWS/ECS"
  metric_name         = "LiveTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = data.terraform_remote_state.ecs.outputs.observability_cluster_name
    ServiceName = aws_ecs_service.gateway[0].name
  }

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}
