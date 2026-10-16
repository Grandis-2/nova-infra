# ─────────────────────────────────────────────────────────────
# 브라우저 수집기 — 프런트 실사용자 모니터링(Grafana Faro)을 받는 Collector
#
#   rum.<도메인>/collect → CloudFront(edge 스택, 전용 WAF · Host 를 그대로 넘긴다) → ALB(ecs 스택) 443
#     → 이 리스너 규칙(Host · 원본 확인 헤더 · 경로) → 수집기 12347 → OTel 게이트웨이 4318
#
# 관측 클러스터에 둔다. 앱 클러스터에서 관측 서비스를 떼어 내는 중이라 새 서비스는 처음부터 여기 만든다.
# 게이트웨이와 같은 Service Connect 네임스페이스를 써서 클러스터가 달라도 otel-gateway.<네임스페이스> 로 보낸다.
# 설정은 게이트웨이처럼 파일 내용을 환경 변수로 넣는다(rum/collector.yaml). obs 태스크의 설정 해시에 들지 않는다.
# ─────────────────────────────────────────────────────────────

locals {
  rum_name    = "${local.name_prefix}-rum-collector"
  rum_domain  = try(data.terraform_remote_state.acm.outputs.rum_domain_name, "")
  rum_sg      = try(data.terraform_remote_state.security.outputs.rum_collector_security_group_id, "")
  rum_enabled = local.rum_domain != "" && local.rum_sg != ""

  rum_cluster = {
    arn  = data.terraform_remote_state.ecs.outputs.observability_cluster_arn
    name = data.terraform_remote_state.ecs.outputs.observability_cluster_name
  }
  rum_ports = { faro = 12347, health = 13133 }

  # 프런트 출처. apex 는 www 로 옮겨 가지만 받아도 해가 없어 같이 둔다. Vercel 미리보기(*.vercel.app)는 누구나 띄울 수 있어 넣지 않는다
  rum_allowed_origins = ["https://www.grandis-nova.link", "https://grandis-nova.link"]
}

resource "aws_cloudwatch_log_group" "rum" {
  #checkov:skip=CKV_AWS_158:컨테이너 로그다. 다른 서비스 로그 그룹과 같이 기본 암호화(AWS 관리)를 쓴다
  #checkov:skip=CKV_AWS_338:관측 경로 자체의 로그라 서비스 로그와 같은 보존 기간이면 된다
  name              = "/ecs/${local.rum_name}"
  retention_in_days = var.obs_log_retention_days
}

resource "aws_ecs_task_definition" "rum" {
  count = local.rum_enabled ? 1 : 0

  family                   = local.rum_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
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
        { name = "COLLECTOR_CONFIG", value = file("${path.module}/rum/collector.yaml") },
        { name = "RUM_ALLOWED_ORIGINS", value = jsonencode(local.rum_allowed_origins) },
        { name = "GATEWAY_OTLP_ENDPOINT", value = "http://otel-gateway.${local.gateway_namespace}:${local.obs_ports.otlp_http}" },
      ]
      portMappings = [
        { name = "faro", containerPort = local.rum_ports.faro, protocol = "tcp", appProtocol = "http" },
        { name = "health", containerPort = local.rum_ports.health, protocol = "tcp" },
      ]
      readonlyRootFilesystem = true
      stopTimeout            = 15
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.rum.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "otel-collector"
        }
      }
      linuxParameters = local.obs_common.linuxParameters
    },
  ])
}

# 리스너 기본 인증서는 API 것이다. 수집 주소 이름은 SNI 로 더 붙인다
resource "aws_lb_listener_certificate" "rum" {
  count = local.rum_enabled ? 1 : 0

  listener_arn    = data.aws_lb_listener.https.arn
  certificate_arn = data.terraform_remote_state.acm.outputs.rum_alb_certificate_arn
}

resource "aws_lb_target_group" "rum" {
  count = local.rum_enabled ? 1 : 0

  name        = "${local.name_prefix}-rum"
  port        = local.rum_ports.faro
  protocol    = "HTTP"
  vpc_id      = data.aws_subnet.obs.vpc_id
  target_type = "ip"

  deregistration_delay = 10

  health_check {
    enabled             = true
    port                = tostring(local.rum_ports.health)
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name_prefix}-rum", Service = "rum-collector" }
}

# Grafana(1) 다음, 서비스 규칙(10~90) 앞. Host 로 가르므로 API 와 겹치지 않는다
resource "aws_lb_listener_rule" "rum" {
  count = local.rum_enabled ? 1 : 0

  listener_arn = data.aws_lb_listener.https.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rum[0].arn
  }

  condition {
    host_header {
      values = [local.rum_domain]
    }
  }

  condition {
    path_pattern {
      values = ["/collect"]
    }
  }

  condition {
    http_header {
      http_header_name = data.terraform_remote_state.ecs.outputs.origin_verify_header.name
      # remote state 로 읽은 값은 sensitive 표시가 풀려 plan(Atlantis PR 댓글)에 그대로 찍힌다. 다시 가린다
      values = [sensitive(data.terraform_remote_state.ecs.outputs.origin_verify_header.value)]
    }
  }

  tags = { Name = "${local.name_prefix}-rum" }

  # SNI 인증서가 붙은 뒤에 규칙을 연다
  depends_on = [aws_lb_listener_certificate.rum]
}

resource "aws_ecs_service" "rum" {
  count = local.rum_enabled ? 1 : 0

  name            = local.rum_name
  cluster         = local.rum_cluster.arn
  task_definition = aws_ecs_task_definition.rum[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = false
  propagate_tags         = "SERVICE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = data.terraform_remote_state.vpc.outputs.app_subnet_ids
    security_groups  = [local.rum_sg]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.rum[0].arn
    container_name   = "otel-collector"
    container_port   = local.rum_ports.faro
  }

  # 내놓는 이름은 없고, 게이트웨이 별칭(otel-gateway.<네임스페이스>)만 쓴다
  service_connect_configuration {
    enabled   = true
    namespace = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_arn
  }

  depends_on = [aws_lb_listener_rule.rum]

  # 대수는 오토스케일링이 정한다
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# 판매 오픈처럼 사용자가 몰리면 늘린다. 상한 3대는 실측 전 추정이다(한 대가 초당 수백 요청, 오픈 때 예상 유입은 그 1/4~1/2).
# 늘려도 브라우저 로그(대부분의 양)는 Loki 수집 한도(테넌트 초당 4 MB)에 묶인다. 트레이스는 Tempo 로 간다. 자체 지표(job="rum-collector")를 본 뒤 조정한다.
# 상태를 들고 있지 않아 줄여도 잃는 것이 거의 없다
resource "aws_appautoscaling_target" "rum" {
  count = local.rum_enabled ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${local.rum_cluster.name}/${aws_ecs_service.rum[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = 3
}

resource "aws_appautoscaling_policy" "rum_cpu" {
  count = local.rum_enabled ? 1 : 0

  name               = "${local.rum_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.rum[0].service_namespace
  resource_id        = aws_appautoscaling_target.rum[0].resource_id
  scalable_dimension = aws_appautoscaling_target.rum[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# 수집기가 없으면 프런트 기록이 모두 사라진다(앱 관측에는 영향 없다)
resource "aws_cloudwatch_metric_alarm" "rum_no_task" {
  count = local.rum_enabled ? 1 : 0

  alarm_name          = "${local.rum_name}-no-tasks"
  alarm_description   = "Browser RUM collector has no running task. Frontend errors, web vitals and browser traces are being dropped"
  namespace           = "AWS/ECS"
  metric_name         = "LiveTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = local.rum_cluster.name
    ServiceName = aws_ecs_service.rum[0].name
  }

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}
