# ─────────────────────────────────────────────────────────────
# monitoring — 경보와 대시보드
#
# 경보는 사람이 바로 조치할 것만 만든다. 할 일 없는 경보는 무시하게 되고 진짜 장애를 놓친다.
#
#   사용자가 이미 아프다 : ALB 가 만든 5xx, 태스크 0개, CloudFront 5xx (edge.tf)
#                          서비스가 낸 5xx · 증설 한계 · 늘릴 수 없는 서비스의 CPU 는 ecs 모듈(<서비스>-5xx · -at-max · -cpu-high),
#                          응답 시간 · 가용성은 Grafana SLO 경보
#   곧 아파진다          : 큐 적체, Valkey, RDS(var.rds_instance_ids. NCP DB 는 NCP Cloud Insight 알림)
#   조용히 실패했다      : DLQ 적재, 배치 태스크 비정상 종료
#   공격 · 차단          : WAF 차단 급증 (edge.tf)
#   트래픽이 없어도      : 인증서 만료 (certs_alb.tf)
#   엣지 설정 어긋남     : ALB 가 직접 만든 4xx 비율, 요청 5분 20건 이상일 때 (certs_alb.tf)
#
# 경보는 SNS 토픽으로 모으고 Slack 채널로 보낸다 (slack.tf).
# CloudFront · 글로벌 WAF 지표는 us-east-1 에만 있어 그 경보와 토픽은 us-east-1 에 둔다.
# ─────────────────────────────────────────────────────────────

locals {
  alb_suffix    = data.terraform_remote_state.ecs.outputs.alb_arn_suffix
  cluster_name  = data.terraform_remote_state.ecs.outputs.cluster_name
  service_names = data.terraform_remote_state.ecs.outputs.service_names
  # 배치 태스크 group (ecs 출력). singleton 서비스(service:…)와 Scheduler 단발 태스크(family:…)
  batch_task_groups = try(data.terraform_remote_state.ecs.outputs.batch_task_groups, [])

  queues         = data.terraform_remote_state.sqs.outputs.queues
  sched_dlq_name = data.terraform_remote_state.sqs.outputs.scheduler_dlq.name

  valkey_nodes = sort(flatten([for rg in data.aws_elasticache_replication_group.valkey : rg.member_clusters]))
  valkey_alarms = {
    cpu       = { metric = "EngineCPUUtilization", statistic = "Average", threshold = 80, periods = 3, description = "engine CPU above 80% (single thread)" }
    memory    = { metric = "DatabaseMemoryUsagePercentage", statistic = "Maximum", threshold = 80, periods = 2, description = "memory above 80%. Evictions come next" }
    evictions = { metric = "Evictions", statistic = "Sum", threshold = 0, periods = 1, description = "keys were evicted. Queue or session data may be lost" }
  }

  # 연결 사용률 · 수집 끊김 · 오래 도는 쿼리는 엔진 지표라 Grafana 경보(lgtm 스택)가 본다
  rds_alarms = {
    cpu     = { metric = "CPUUtilization", statistic = "Average", comparison = "GreaterThanThreshold", threshold = 80, periods = 3, description = "CPU above 80% for 15 minutes" }
    memory  = { metric = "FreeableMemory", statistic = "Minimum", comparison = "LessThanThreshold", threshold = 256 * 1024 * 1024, periods = 3, description = "freeable memory below 256 MiB for 15 minutes. Swap comes next" }
    storage = { metric = "FreeStorageSpace", statistic = "Minimum", comparison = "LessThanThreshold", threshold = var.rds_free_storage_threshold_gib * 1024 * 1024 * 1024, periods = 1, description = "free storage below ${var.rds_free_storage_threshold_gib} GiB" }
  }
}

# 쓰기 엔드포인트에서 그룹 ID 를 얻어 노드 목록을 읽는다.
# TLS 를 켜면 master.<그룹 ID>.<…>, 끄면 <그룹 ID>.<…> 형식이다
data "aws_elasticache_replication_group" "valkey" {
  for_each = data.terraform_remote_state.elasticache.outputs.redis_endpoints

  replication_group_id = regex("^(?:master\\.)?([^.]+)\\.", each.value)[0]
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = { Name = "${local.name_prefix}-alerts" }
}

# ── 사용자가 이미 아프다 ─────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx"
  alarm_description   = "The ALB itself returned 5xx: no healthy targets, target timeout or connection error. 5xx from the apps are in <service>-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { LoadBalancer = local.alb_suffix }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = data.terraform_remote_state.ecs.outputs.target_group_arn_suffixes

  alarm_name          = "${local.name_prefix}-unhealthy-${each.key}"
  alarm_description   = "Target group ${each.key} has unhealthy targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_suffix
    TargetGroup  = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# 태스크가 하나도 없으면 트래픽이 없을 때는 다른 경보가 울리지 않는다 (기동 실패, Spot 회수, 이미지 오류)
resource "aws_cloudwatch_metric_alarm" "no_running_tasks" {
  for_each = local.service_names

  alarm_name        = "${local.name_prefix}-${each.key}-no-tasks"
  alarm_description = "${each.value} has no running tasks. Check stopped task reasons and logs"
  # AWS/ECS 의 무료 태스크 수 지표. Container Insights 를 쓰지 않는다
  namespace           = "AWS/ECS"
  metric_name         = "LiveTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5 # 배포 · singleton 재시작으로 잠깐 0 이 되는 것은 넘긴다
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # 지표가 끊긴 것도 태스크가 없는 것으로 본다

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── 곧 아파진다 ──────────────────────────────────────────────
# NCP DB 는 CloudWatch 지표가 없어 NCP Cloud Insight 알림(CPU, 디스크, 연결 수)으로 본다. RDS 는 아래 rds 경보다.

# Valkey: 대기열 · 세션이 여기 있다. 메모리가 차서 키가 밀려나면(eviction) 대기 순번이 사라진다
resource "aws_cloudwatch_metric_alarm" "valkey" {
  for_each = {
    # 노드 ID(nova-prod-valkey-001)에 이미 접두사가 있다
    for p in setproduct(local.valkey_nodes, keys(local.valkey_alarms)) : "${p[0]}-${p[1]}" => {
      node = p[0]
      spec = local.valkey_alarms[p[1]]
    }
  }

  alarm_name          = each.key
  alarm_description   = "${each.value.node}: ${each.value.spec.description}"
  namespace           = "AWS/ElastiCache"
  metric_name         = each.value.spec.metric
  statistic           = each.value.spec.statistic
  period              = 300
  evaluation_periods  = each.value.spec.periods
  threshold           = each.value.spec.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { CacheClusterId = each.value.node }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# RDS: 인스턴스마다 CPU · 메모리 · 스토리지
resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = {
    for p in setproduct(var.rds_instance_ids, keys(local.rds_alarms)) : "${p[0]}-${p[1]}" => {
      instance = p[0]
      spec     = local.rds_alarms[p[1]]
    }
  }

  alarm_name          = each.key
  alarm_description   = "${each.value.instance}: ${each.value.spec.description}"
  namespace           = "AWS/RDS"
  metric_name         = each.value.spec.metric
  statistic           = each.value.spec.statistic
  period              = 300
  evaluation_periods  = each.value.spec.periods
  threshold           = each.value.spec.threshold
  comparison_operator = each.value.spec.comparison
  treat_missing_data  = "notBreaching"

  dimensions = { DBInstanceIdentifier = each.value.instance }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# RDS 이전 기간의 NCP → RDS 복제. 덤프와 전환 사이(몇 주)에 복제가 멈추면 binlog 보존(7일) 안에 알아야 덤프를 다시 하지 않는다.
# ReplicaLag 는 문서상 읽기 복제본 지표이고, 외부 소스 복제에서도 나오는지는 문서에 없다(복제를 시작한 뒤 지표가 보이는지 확인한다).
# 그래서 지표가 아예 없어도 경보가 울리게(breaching) 둔다. 울리면 SHOW REPLICA STATUS 로 먼저 본다.
#   lag     지연이 rds_replication_lag_threshold 초를 5분 넘게 넘는다
#   stopped 복제 스레드가 멈췄다(-1) 또는 지표가 없다
resource "aws_cloudwatch_metric_alarm" "rds_replication" {
  for_each = var.rds_replication_alarm_instance == "" ? {} : {
    lag     = { statistic = "Maximum", comparison = "GreaterThanThreshold", threshold = var.rds_replication_lag_threshold, missing = "notBreaching", description = "replication from NCP is more than ${var.rds_replication_lag_threshold}s behind" }
    stopped = { statistic = "Minimum", comparison = "LessThanThreshold", threshold = 0, missing = "breaching", description = "replication from NCP is not running (ReplicaLag -1 or missing). Check SHOW REPLICA STATUS" }
  }

  alarm_name          = "${var.rds_replication_alarm_instance}-replication-${each.key}"
  alarm_description   = "${var.rds_replication_alarm_instance}: ${each.value.description}"
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  statistic           = each.value.statistic
  period              = 60
  evaluation_periods  = 5
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = each.value.missing

  dimensions = { DBInstanceIdentifier = var.rds_replication_alarm_instance }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# 큐 이름 오타는 문턱이 조용히 기본값으로 남으므로 알린다
check "queue_age_overrides" {
  assert {
    condition     = length(setsubtract(keys(var.queue_age_threshold_overrides), keys(local.queues))) == 0
    error_message = "queue_age_threshold_overrides 에 없는 큐가 있다: ${join(", ", setsubtract(keys(var.queue_age_threshold_overrides), keys(local.queues)))}"
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = local.queues

  alarm_name          = "${local.name_prefix}-${each.key}-age"
  alarm_description   = "Oldest message age is above the threshold. Consumers are falling behind"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = lookup(var.queue_age_threshold_overrides, each.key, var.queue_age_threshold_seconds)
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { QueueName = each.value.name }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ── 조용히 실패했다 ──────────────────────────────────────────
# DLQ 메시지는 재시도를 모두 실패한 것이므로 한 건만 쌓여도 알린다.
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = merge(
    { for k, q in local.queues : k => q.dlq_name },
    { scheduler = local.sched_dlq_name },
  )

  alarm_name          = "${local.name_prefix}-${each.key}-dlq"
  alarm_description   = "${each.value} has messages. Find the cause, then redrive"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { QueueName = each.value }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# 배치 태스크가 비정상 종료하면 알린다. 상시 배치(정합성 검사)는 ECS 가 새로 띄우고, 단발 배치(사진 정리)는
# 다음 날까지 다시 돌지 않으므로 둘 다 겉으로는 잘 드러나지 않는다.
#
# group 으로 배치 태스크만 거르고(ecs 출력 batch_task_groups), 정상 종료(0)와 배포 · Spot 회수 때의 종료 코드
# (143 = SIGTERM)는 뺀다. 이미지를 못 받는 등 컨테이너가 뜨지 못한 태스크는 종료 코드가 없어 stopCode 로 잡는다.
resource "aws_cloudwatch_event_rule" "batch_failure" {
  # 배치가 모두 deploy: false 면 감시할 것이 없다
  count = length(local.batch_task_groups) > 0 ? 1 : 0

  name        = "${local.name_prefix}-batch-task-failed"
  description = "Batch task stopped abnormally"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      lastStatus = ["STOPPED"]
      clusterArn = [data.terraform_remote_state.ecs.outputs.cluster_arn]
      group      = local.batch_task_groups
      "$or" = [
        { containers = { exitCode = [{ "anything-but" = [0, 143] }] } },
        { stopCode = ["TaskFailedToStart"] },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "batch_failure" {
  count = length(aws_cloudwatch_event_rule.batch_failure)

  rule      = aws_cloudwatch_event_rule.batch_failure[0].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn

  # Chatbot 은 ECS 이벤트 원문을 Slack 에 그리지 못한다. 사용자 정의 알림 형식으로 바꿔 보낸다
  input_transformer {
    # 종료 코드로 원인을 가른다. batch-imagecleanup 의 2 는 예외가 아니라 삭제 대기가 며칠째 남아 멈췄다는 뜻이다(1 = 예외).
    # 뜨지 못한 태스크(stopCode TaskFailedToStart)는 컨테이너가 없어 종료 코드 자리가 비고, 이유는 stoppedReason 에 있다
    input_paths = {
      group  = "$.detail.group"
      task   = "$.detail.taskArn"
      reason = "$.detail.stoppedReason"
      stop   = "$.detail.stopCode"
      exit   = "$.detail.containers[0].exitCode"
    }
    input_template = <<-EOT
      {"version": "1.0", "source": "custom", "content": {"title": "Batch task stopped abnormally: <group>", "description": "<stop>: <reason>. Exit code (only when the container ran): <exit> (imagecleanup 2 = deletions blocked for days, 1 = exception). Task <task>"}}
    EOT
  }
}

data "aws_iam_policy_document" "sns" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns.json
}
