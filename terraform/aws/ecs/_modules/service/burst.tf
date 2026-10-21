# ─────────────────────────────────────────────────────────────
# 순간 폭주 증설 — 먼저 늘리고 Slack 에 알린다 (단계 조정, NV-750)
#
# 대상 추적의 경보는 AWS 가 "1분 지표 3번 연속"으로 고정해 둬서, 몰리고 나서 증설이 시작되기까지 3분이 넘는다.
# 여기서는 1분 지표를 1~2번만 보고 바로 늘리는 경보를 따로 둔다. 대상 추적(main.tf)은 평상시 증설과 축소를 맡는다.
#
#   cpu      CPU 가 burst_cpu(%)를 2번 연속 넘으면. 새 태스크가 JVM 을 띄우는 1분 동안 CPU 가 치솟아, 1번만 보면
#            증설이 다시 증설을 부른다
#   requests 태스크 하나가 1분에 받은 요청이 burst_requests_per_task 를 1번 넘으면 (규칙 · blue · green 대상 그룹 합)
#   backlog  태스크 하나에 밀린 메시지가 queue_backlog 목표의 2배를 1번 넘으면
#
# 늘리는 폭은 지금 대수에 비례한다: 기준 ~ 기준의 2배(cpu 는 +20%p) 구간이면 +100%, 그 위면 +200% (최소 1대, max 까지).
# 경보가 울려 있는 동안 1분마다 다시 판단해 더 늘린다. 경보 상태가 바뀔 때마다 alarm_topic_arn(Slack)에 알린다.
# ─────────────────────────────────────────────────────────────

locals {
  burst_on = var.create_service && var.max_capacity > 0

  # 종류 → 경보 기준과 +200% 로 넘어가는 폭(기준 위로 얼마나 더)
  burst = merge(
    local.burst_on && var.burst_cpu > 0 ? { cpu = { threshold = var.burst_cpu, band = 20 } } : {},
    local.burst_on && var.burst_requests_per_task > 0 && length(var.routes) > 0 ? {
      requests = { threshold = var.burst_requests_per_task, band = var.burst_requests_per_task }
    } : {},
    local.burst_on && var.queue_backlog != null ? {
      backlog = { threshold = 2 * var.queue_backlog.target_per_task, band = 2 * var.queue_backlog.target_per_task }
    } : {},
  )

  # 요청 수 = 이 서비스의 모든 대상 그룹 요청 합. 대기 중인 쪽(blue 또는 green)은 데이터가 없어 0 으로 채운다
  burst_tg_keys = sort(keys(local.target_groups))
  # 태스크 수가 0 이거나 지표가 끊기면 1 로 나눈다(main.tf 의 적체 대상 추적과 같다). 그래야 0대에서도 늘릴 수 있다
  burst_tasks_expr = "IF(FILL(tasks, 1) < 1, 1, FILL(tasks, 1))"
  burst_requests_expr = format(
    "(%s) / ${local.burst_tasks_expr}",
    join(" + ", [for i, k in local.burst_tg_keys : "FILL(r${i}, 0)"]),
  )

  burst_message = {
    cpu      = "${var.name}: CPU above ${var.burst_cpu}% for 2 minutes. Scaling out now (+100% to +200%, up to ${var.max_capacity} tasks)"
    requests = "${var.name}: requests per task above ${var.burst_requests_per_task}/min. Scaling out now (+100% to +200%, up to ${var.max_capacity} tasks)"
    backlog  = "${var.name}: queue backlog per task above ${try(2 * var.queue_backlog.target_per_task, 0)}. Scaling out now (+100% to +200%, up to ${var.max_capacity} tasks)"
  }
}

resource "aws_appautoscaling_policy" "burst" {
  for_each = local.burst

  name               = "${var.name}-burst-${each.key}"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    min_adjustment_magnitude = 1  # 1대일 때 +100% 가 1대가 되도록
    cooldown                 = 60 # 새 태스크가 뜨는 동안 같은 폭주로 두 번 늘리지 않는다
    metric_aggregation_type  = "Average"

    # 구간은 경보 기준으로부터의 거리다
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = each.value.band
      scaling_adjustment          = 100
    }

    step_adjustment {
      metric_interval_lower_bound = each.value.band
      scaling_adjustment          = 200
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "burst_cpu" {
  count = contains(keys(local.burst), "cpu") ? 1 : 0

  alarm_name          = "${var.name}-burst-cpu"
  alarm_description   = local.burst_message.cpu
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.burst_cpu
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.name
  }

  alarm_actions = compact([aws_appautoscaling_policy.burst["cpu"].arn, var.alarm_topic_arn])
  ok_actions    = compact([var.alarm_topic_arn])

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "burst_requests" {
  count = contains(keys(local.burst), "requests") ? 1 : 0

  lifecycle {
    # 지표 수식 경보는 지표를 10개까지 받는다(대상 그룹 + 태스크 수). Blue/Green 은 규칙 하나에 대상 그룹 2개라 규칙 4개까지다
    precondition {
      condition     = length(local.burst_tg_keys) + 1 <= 10
      error_message = "${var.name}: 대상 그룹이 ${length(local.burst_tg_keys)}개라 요청 수 경보의 지표 한도(10)를 넘는다. routes 를 줄이거나 scaling.requests_per_task 를 0 으로 둔다."
    }
  }

  alarm_name          = "${var.name}-burst-requests"
  alarm_description   = local.burst_message.requests
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.burst_requests_per_task
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dynamic "metric_query" {
    for_each = local.burst_tg_keys

    content {
      id = "r${metric_query.key}"

      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = "RequestCount"
        period      = 60
        stat        = "Sum"

        dimensions = {
          LoadBalancer = var.alb_arn_suffix
          TargetGroup  = aws_lb_target_group.this[metric_query.value].arn_suffix
        }
      }
    }
  }

  metric_query {
    id = "tasks"

    metric {
      # 서비스 태스크 수(AWS/ECS, 무료). Blue/Green 배포 중에는 두 묶음을 다 세어 낮게 잡힌다 — 덜 늘리는 쪽이라 둔다
      namespace   = "AWS/ECS"
      metric_name = "LiveTaskCount"
      period      = 60
      stat        = "Average"

      dimensions = {
        ClusterName = var.cluster_name
        ServiceName = var.name
      }
    }
  }

  metric_query {
    id          = "per_task"
    expression  = local.burst_requests_expr
    label       = "Requests per task per minute"
    return_data = true
  }

  alarm_actions = compact([aws_appautoscaling_policy.burst["requests"].arn, var.alarm_topic_arn])
  ok_actions    = compact([var.alarm_topic_arn])

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "burst_backlog" {
  count = contains(keys(local.burst), "backlog") ? 1 : 0

  alarm_name          = "${var.name}-burst-backlog"
  alarm_description   = local.burst_message.backlog
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 2 * var.queue_backlog.target_per_task
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dynamic "metric_query" {
    for_each = var.queue_backlog.queue_names

    content {
      id = "q${metric_query.key}"

      metric {
        namespace   = "AWS/SQS"
        metric_name = "ApproximateNumberOfMessagesVisible"
        period      = 60
        stat        = "Average"

        dimensions = { QueueName = metric_query.value }
      }
    }
  }

  metric_query {
    id = "tasks"

    metric {
      namespace   = "AWS/ECS"
      metric_name = "LiveTaskCount"
      period      = 60
      stat        = "Average"

      dimensions = {
        ClusterName = var.cluster_name
        ServiceName = var.name
      }
    }
  }

  metric_query {
    id          = "per_task"
    expression  = format("(%s) / %s", join(" + ", [for i, q in var.queue_backlog.queue_names : "FILL(q${i}, 0)"]), local.burst_tasks_expr)
    label       = "Backlog per task"
    return_data = true
  }

  alarm_actions = compact([aws_appautoscaling_policy.burst["backlog"].arn, var.alarm_topic_arn])
  ok_actions    = compact([var.alarm_topic_arn])

  tags = var.tags
}
