# ─────────────────────────────────────────────────────────────
# ecs-service — 로그 그룹, 태스크 정의, 서비스, 오토스케일링 (ALB 라우팅은 alb.tf)
#
# create_service = false 면 태스크 정의만 만든다 (Scheduler 가 RunTask 로 띄우는 배치용).
# ─────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

locals {
  port_mappings = [for i, p in [for x in distinct([var.port, var.extra_port]) : x if x > 0] : {
    containerPort = p
    protocol      = "tcp"
    name          = i == 0 ? "http" : "mgmt"
  }]

  health_check = length(var.health_check_command) > 0 ? {
    command     = var.health_check_command
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  } : null

  container = {
    name      = var.name
    image     = var.image
    essential = true

    portMappings = local.port_mappings

    environment = [for k, v in var.environment : { name = k, value = v }]
    secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "app"
      }
    }

    healthCheck = local.health_check
    stopTimeout = var.stop_timeout
  }
}

data "aws_region" "current" {}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    { for k, v in local.container : k => v if v != null }
  ])

  tags = var.tags
}

# ALB 연결 모양 (배포 방식 · 경로 수 · 타깃 그룹). 서비스의 load_balancer 는 Blue/Green 때문에 무시하므로,
# 이 모양이 바뀌면(롤링 ↔ Blue/Green, 경로 추가, 타깃 그룹 교체) 서비스를 다시 만들어 반영한다.
# 같은 이름으로 지운 뒤 만들므로(provider 가 INACTIVE 까지 기다림) 그동안 서비스가 잠깐 멈춘다. 드문 구조 변경이라 감수한다
resource "terraform_data" "lb_shape" {
  input = {
    blue_green    = var.blue_green
    routes        = length(var.routes)
    target_groups = sort([for tg in aws_lb_target_group.this : tg.arn])
  }
}

# ── 서비스 ───────────────────────────────────────────────────
resource "aws_ecs_service" "this" {
  count = var.create_service ? 1 : 0

  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  # 태스크를 두 AZ 에 나눠 배치한다. AZ 하나가 죽어도 서비스가 남는다.
  # singleton 은 끈다 — AWS 가 최대 100% 배포와 함께 받지 않고, 태스크가 1개라 나눌 것도 없다
  availability_zone_rebalancing = var.singleton ? "DISABLED" : "ENABLED"

  # 용량 공급자(FARGATE ↔ SPOT)를 바꾸면 ECS 는 새 배포를 요구한다
  force_new_deployment = true

  # 온디맨드를 on_demand_base 개 남기고, 그 위로 늘어나는 태스크는 Spot 으로 띄운다.
  # 1 이면 Spot 이 회수돼도 서비스가 0 이 되지 않는다. 0 이면 전부 Spot (가장 싸다).
  dynamic "capacity_provider_strategy" {
    for_each = var.use_spot ? [
      { provider = "FARGATE", base = var.on_demand_base, weight = 0 },
      { provider = "FARGATE_SPOT", base = 0, weight = 1 },
      ] : [
      { provider = "FARGATE", base = 0, weight = 1 },
    ]

    content {
      capacity_provider = capacity_provider_strategy.value.provider
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false # 앱 서브넷에는 공인 IP 가 없다
  }

  # ALB 규칙마다 타깃 그룹 하나(롤링) 또는 한 쌍(Blue/Green)
  dynamic "load_balancer" {
    for_each = local.load_balancers

    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = var.name
      container_port   = var.port

      # ECS 자체 Blue/Green: 새 버전을 alternate 타깃 그룹에 띄우고, 헬스체크가 통과하면
      # production_listener_rule 의 대상을 바꾼다. 문제가 생기면 규칙을 되돌린다.
      dynamic "advanced_configuration" {
        for_each = var.blue_green ? [load_balancer.value] : []

        content {
          alternate_target_group_arn = advanced_configuration.value.alternate_target_group_arn
          production_listener_rule   = advanced_configuration.value.production_listener_rule
          role_arn                   = var.lb_role_arn
        }
      }
    }
  }

  # 서비스 간 호출 (Service Connect). Blue/Green 은 Cloud Map 등록(service_registries)을 지원하지 않는다.
  # 모든 서비스가 클라이언트로 참여하고, 포트가 있는 서비스는 <dns_name>:<port> 별칭으로 자신을 내놓는다.
  # 별칭은 태스크 안의 프록시가 풀어 주므로 Service Connect 를 켠 태스크에서만 쓸 수 있다 (RunTask 배치는 못 씀)
  dynamic "service_connect_configuration" {
    for_each = var.create_service ? [1] : []

    content {
      enabled   = true
      namespace = var.service_connect_namespace

      dynamic "service" {
        for_each = var.service_connect_dns_name != "" && var.port > 0 ? [1] : []

        content {
          port_name      = "http"
          discovery_name = var.name

          client_alias {
            port     = var.port
            dns_name = var.service_connect_dns_name
          }
        }
      }
    }
  }

  health_check_grace_period_seconds = length(var.routes) > 0 ? var.health_check_grace_period : null

  deployment_controller {
    type = "ECS"
  }

  # BLUE_GREEN : 새 버전을 다 띄워 확인한 뒤 트래픽을 한 번에 돌린다. bake 시간 동안 옛 버전을 남겨 둔다
  # ROLLING    : 새 태스크가 정상이 되는 만큼 옛 태스크를 내린다
  deployment_configuration {
    strategy             = var.blue_green ? "BLUE_GREEN" : "ROLLING"
    bake_time_in_minutes = var.blue_green ? var.bake_time_in_minutes : null
  }

  # 새 태스크가 계속 죽으면 배포를 멈추고 이전 버전으로 되돌린다.
  # 없으면 망가진 이미지가 재시작만 반복하고 배포가 끝나지 않는다.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 배포 중에도 기존 태스크를 남겨 무중단으로 배포한다 (Blue/Green 도 100/200).
  # singleton(동시에 둘이 뜨면 안 되는 앱)은 옛 태스크를 먼저 내리고 새로 띄운다.
  deployment_minimum_healthy_percent = var.singleton ? 0 : 100
  deployment_maximum_percent         = var.singleton ? 100 : 200

  wait_for_steady_state = false

  lifecycle {
    # task_definition 은 무시하지 않는다. 설정과 이미지 태그는 Terraform 이 관리하고,
    # CI 는 force-new-deployment 로 같은 태그를 다시 받기만 한다.
    replace_triggered_by = [terraform_data.lb_shape]

    ignore_changes = [
      desired_count, # 오토스케일링이 바꾼다
      load_balancer, # Blue/Green 은 배포 때마다 ECS 가 primary/alternate 타깃 그룹을 맞바꾼다
    ]
  }

  tags = var.tags
}

# ── 오토스케일링 ─────────────────────────────────────────────
resource "aws_appautoscaling_target" "this" {
  count = var.create_service && var.max_capacity > 0 ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity

  depends_on = [aws_ecs_service.this]
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.create_service && var.max_capacity > 0 && var.cpu_target > 0 ? 1 : 0

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300 # 트래픽이 출렁여도 태스크 수가 널뛰지 않게 천천히 줄인다
    scale_out_cooldown = 60  # 늘릴 때는 빠르게
  }
}

resource "aws_appautoscaling_policy" "request_count" {
  count = var.create_service && var.max_capacity > 0 && var.request_count_target > 0 ? 1 : 0

  name               = "${var.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.request_count_target

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${aws_lb_target_group.this["0-blue"].arn_suffix}"
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# 큐 적체 기반 스케일링: 메시지 수(큐가 여럿이면 합) / 태스크 수 = 태스크당 밀린 일감
# CPU 로는 대기 중인 일이 보이지 않으므로 컨슈머는 이 지표로 늘린다.
resource "aws_appautoscaling_policy" "queue_backlog" {
  count = var.create_service && var.max_capacity > 0 && var.queue_backlog != null ? 1 : 0

  name               = "${var.name}-backlog"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.queue_backlog.target_per_task

    customized_metric_specification {
      dynamic "metrics" {
        for_each = var.queue_backlog.queue_names

        content {
          id    = "m${metrics.key}"
          label = "Visible messages (${metrics.value})"

          metric_stat {
            metric {
              namespace   = "AWS/SQS"
              metric_name = "ApproximateNumberOfMessagesVisible"

              dimensions {
                name  = "QueueName"
                value = metrics.value
              }
            }

            stat = "Average"
          }

          return_data = false
        }
      }

      metrics {
        id    = "tasks"
        label = "Live tasks"

        metric_stat {
          metric {
            # 서비스 태스크 수(AWS/ECS, 무료). 연결을 정리하며 내려가는 태스크도 센다
            namespace   = "AWS/ECS"
            metric_name = "LiveTaskCount"

            dimensions {
              name  = "ClusterName"
              value = var.cluster_name
            }

            dimensions {
              name  = "ServiceName"
              value = var.name
            }
          }

          stat = "Average"
        }

        return_data = false
      }

      # 태스크가 0 이거나 지표가 비어도(태스크가 없으면 표본이 없다) 나누는 수를 1 로 본다.
      # MAX([tasks, 1]) 은 시계열과 상수를 섞어 CloudWatch 가 거절한다
      metrics {
        id          = "backlog"
        label       = "Backlog per task"
        expression  = "(${join(" + ", [for i, q in var.queue_backlog.queue_names : "m${i}"])}) / IF(FILL(tasks, 1) < 1, 1, FILL(tasks, 1))"
        return_data = true
      }
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
