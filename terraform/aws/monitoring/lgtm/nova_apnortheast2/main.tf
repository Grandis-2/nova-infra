# ─────────────────────────────────────────────────────────────
# lgtm — 관측 스택 (LGTM on ECS, NV-425). CloudWatch 경보 · 대시보드는 monitoring/cloudwatch 스택이다.
#
# 앱 태스크의 OTel 에이전트 ──OTLP──▶ otel.<네임스페이스>:4318 (HTTP) · otel-grpc.<네임스페이스>:4317 (Service Connect)
#   ▶ 이 태스크 하나: otel-collector → loki(로그) · tempo(트레이스) · mimir(지표) ─▶ S3
#                     grafana(조회 · 경보 → SNS → Chatbot → Slack), mysqld_exporter(선택)
#
#   설정   : config/ 를 obs-config 버킷에 올리고(아래 aws_s3_object), config-init 컨테이너가 태스크 시작 때 받는다.
#            파일 내용의 해시가 작업 정의에 들어가므로 설정을 고치면 apply 가 곧 재배포다.
#   실행   : ecs 스택의 obs 용량 공급자(EC2 1대). 데이터 디렉터리는 그 인스턴스의 데이터 EBS 를 bind mount 한다.
#            한 호스트의 디렉터리를 쓰므로 옛 태스크를 먼저 내리고 새 태스크를 띄운다(최소 0 · 최대 100%).
#   접속   : Grafana 포트는 열지 않는다. ECS Exec 포트 포워딩으로만 들어온다.
#
#     aws ssm start-session --target ecs:<클러스터>_<태스크 ID>_<grafana 런타임 ID> \
#       --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
#
# 한 태스크라 컨테이너가 localhost 를 같이 쓴다. 포트가 겹치면 뒤에 뜬 컨테이너가 죽는다 — 아래 obs_ports 가 기준이다.
# ─────────────────────────────────────────────────────────────

locals {
  obs_name = "${local.name_prefix}-obs"

  obs_cluster_arn = data.terraform_remote_state.ecs.outputs.cluster_arn
  obs_mount_path  = data.terraform_remote_state.ecs.outputs.obs_data_mount_path
  obs_data_dirs   = data.terraform_remote_state.ecs.outputs.obs_data_dirs # 디렉터리 -> uid:gid

  obs_config_bucket = data.terraform_remote_state.s3.outputs.obs_config_bucket.id
  obs_config_prefix = "lgtm"

  # config/ 의 설정 파일. 시험 · 문서는 올리지 않는다
  obs_config_files = toset([
    for f in fileset("${path.module}/config", "**") : f
    if !startswith(f, "test/") && !endswith(f, ".md") && !endswith(f, ".sh")
  ])
  obs_config_hash = sha256(join("", [for f in sort(tolist(local.obs_config_files)) : "${f}:${filesha256("${path.module}/config/${f}")}"]))

  # 태스크 안 localhost 포트. config/ 의 설정 파일과 같아야 한다
  obs_ports = {
    otlp_grpc      = 4317 # collector (앱이 보낸다)
    otlp_http      = 4318 # collector
    loki_http      = 3100
    tempo_http     = 3200
    tempo_otlp     = 14317 # collector → tempo (OTLP gRPC). 4317 은 collector 가 쓴다
    mimir_http     = 9009
    grafana        = 3000
    mysqld_metrics = 9104
  }

  # 이미지는 태그와 다이제스트로 고정한다 (linux/arm64 · linux/amd64 매니페스트). config/test/compose.yaml 과 같아야 한다
  obs_images = {
    aws_cli        = "amazon/aws-cli:2.37.12@sha256:ce44b800602264c12298bbf3399055a4cefdb9ed4a098abe564afe26e7071bce"
    otel_collector = "otel/opentelemetry-collector-contrib:0.162.0@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6"
    loki           = "grafana/loki:3.7.8@sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193"
    tempo          = "grafana/tempo:2.10.5@sha256:ee21727732c7a7199cb71c3eee9153bbf23f9b0b87619f0555a0cf21a67f1a33"
    mimir          = "grafana/mimir:3.2.2@sha256:04068a0a838b6efe9449a04c1d6acd74c7438ac6073dfcbb99c29892647525e3"
    grafana        = "grafana/grafana:12.4.12@sha256:83be3e511ede559bee80e2215bb1987cb1246075461cb961beb515b0341e7aea"
    mysqld_exp     = "prom/mysqld-exporter:v0.20.0@sha256:abed8dac117b4ae5b70757f988e44795935b9a72c3b58d720c67ba688f8cb79e"
  }

  obs_log_group = "/ecs/${local.obs_name}"

  # 모든 컨테이너 공통: 리눅스 권한을 모두 버리고(1024 위 포트만 쓴다), 죽으면 태스크를 내리지 않고 그 컨테이너만 다시 띄운다
  obs_common = {
    linuxParameters = { capabilities = { drop = ["ALL"] } }
    restartPolicy   = { enabled = true, restartAttemptPeriod = 60 }
  }

  obs_log = { for c in ["config-init", "otel-collector", "loki", "tempo", "mimir", "grafana", "mysqld-exporter"] : c => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = local.obs_log_group
      awslogs-region        = var.aws_region
      awslogs-stream-prefix = c
    }
  } }

  obs_after_config = [{ containerName = "config-init", condition = "SUCCESS" }]
  obs_config_mount = [{ sourceVolume = "config", containerPath = "/config", readOnly = true }]

  obs_mysqld_exporter = var.obs_mysqld_exporter.secret_arn != ""

  # 경보 토픽은 monitoring/cloudwatch 스택이 만든다 (Chatbot → Slack 이 이미 구독)
  alerts_topic_arn = data.aws_sns_topic.alerts.arn
  cluster_name     = data.terraform_remote_state.ecs.outputs.cluster_name

  obs_containers = concat(
    [
      # 설정 파일을 받는다. 끝나면 내려간다(essential=false). 나머지는 이것이 성공해야 뜬다
      {
        name      = "config-init"
        image     = local.obs_images.aws_cli
        essential = false
        memory    = 128
        command   = ["s3", "cp", "--recursive", "--only-show-errors", "s3://${local.obs_config_bucket}/${local.obs_config_prefix}/", "/config/"]
        # 값은 쓰지 않는다. 설정이 바뀌면 작업 정의가 바뀌어 새 태스크가 뜨게 하는 표시다
        environment = [
          { name = "OBS_CONFIG_HASH", value = local.obs_config_hash },
          { name = "AWS_REGION", value = var.aws_region },
        ]
        mountPoints      = [{ sourceVolume = "config", containerPath = "/config", readOnly = false }]
        logConfiguration = local.obs_log["config-init"]
        linuxParameters  = local.obs_common.linuxParameters
      },
      {
        name      = "otel-collector"
        image     = local.obs_images.otel_collector
        essential = true
        memory    = 1024
        command   = ["--config=/config/collector.yaml"]
        environment = [
          { name = "LOKI_OTLP_ENDPOINT", value = "http://localhost:${local.obs_ports.loki_http}/otlp" },
          { name = "TEMPO_OTLP_ENDPOINT", value = "localhost:${local.obs_ports.tempo_otlp}" },
          { name = "MIMIR_OTLP_ENDPOINT", value = var.obs_metrics_enabled ? "http://localhost:${local.obs_ports.mimir_http}/otlp" : "" },
          { name = "MYSQLD_EXPORTER_TARGET", value = local.obs_mysqld_exporter ? "localhost:${local.obs_ports.mysqld_metrics}" : "" },
        ]
        # Service Connect 가 이 이름으로 앱 요청을 받는다
        portMappings = [
          { name = "otlp-grpc", containerPort = local.obs_ports.otlp_grpc, protocol = "tcp", appProtocol = "grpc" },
          { name = "otlp-http", containerPort = local.obs_ports.otlp_http, protocol = "tcp", appProtocol = "http" },
        ]
        mountPoints            = local.obs_config_mount
        dependsOn              = concat(local.obs_after_config, [{ containerName = "loki", condition = "START" }])
        readonlyRootFilesystem = true
        logConfiguration       = local.obs_log["otel-collector"]
        linuxParameters        = local.obs_common.linuxParameters
        restartPolicy          = local.obs_common.restartPolicy
      },
      # 정상 종료 때 메모리의 청크를 S3 로 올린다(flush_on_shutdown). stopTimeout 이 그 시간이다
      {
        name      = "loki"
        image     = local.obs_images.loki
        essential = true
        memory    = 2048
        user      = local.obs_data_dirs["loki"]
        command   = ["-config.file=/config/loki.yaml", "-config.expand-env=true"]
        environment = [
          { name = "LOKI_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.loki_bucket.id },
          { name = "LOKI_S3_REGION", value = var.aws_region },
          { name = "LOKI_RETENTION_PERIOD", value = var.obs_retention.logs },
        ]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "loki-data", containerPath = "/loki", readOnly = false }])
        dependsOn        = local.obs_after_config
        stopTimeout      = 120
        logConfiguration = local.obs_log["loki"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
      {
        name      = "tempo"
        image     = local.obs_images.tempo
        essential = true
        memory    = 1536
        user      = local.obs_data_dirs["tempo"]
        command   = ["-config.file=/config/tempo.yaml", "-config.expand-env=true"]
        environment = [
          { name = "TEMPO_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.tempo_bucket.id },
          { name = "TEMPO_S3_REGION", value = var.aws_region },
          { name = "TEMPO_RETENTION", value = var.obs_retention.traces },
        ]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "tempo-data", containerPath = "/var/tempo", readOnly = false }])
        dependsOn        = local.obs_after_config
        stopTimeout      = 120
        logConfiguration = local.obs_log["tempo"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
      {
        name      = "grafana"
        image     = local.obs_images.grafana
        essential = true
        memory    = 512
        user      = local.obs_data_dirs["grafana"]
        environment = [
          { name = "GF_PATHS_PROVISIONING", value = "/config/grafana/provisioning" },
          { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "false" },
          { name = "GF_USERS_ALLOW_SIGN_UP", value = "false" },
          { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
          { name = "GF_SECURITY_DISABLE_GRAVATAR", value = "true" },
          { name = "GF_ANALYTICS_REPORTING_ENABLED", value = "false" },
          { name = "GF_ANALYTICS_CHECK_FOR_UPDATES", value = "false" },
          { name = "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES", value = "false" },
          { name = "GF_NEWS_NEWS_FEED_ENABLED", value = "false" },
          { name = "GF_PLUGINS_PLUGIN_ADMIN_ENABLED", value = "false" },
          { name = "LOKI_URL", value = "http://localhost:${local.obs_ports.loki_http}" },
          { name = "TEMPO_URL", value = "http://localhost:${local.obs_ports.tempo_http}" },
          { name = "MIMIR_URL", value = var.obs_metrics_enabled ? "http://localhost:${local.obs_ports.mimir_http}/prometheus" : "" },
          { name = "SNS_TOPIC_ARN", value = local.alerts_topic_arn },
          { name = "AWS_REGION", value = var.aws_region },
        ]
        # 최초 기동 때만 admin 에 쓰인다. 이미 있는 admin 의 비밀번호 교체는 config/README.md
        secrets = [
          { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = data.terraform_remote_state.secretsmanager.outputs.grafana_admin_secret_arn },
        ]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "grafana-data", containerPath = "/var/lib/grafana", readOnly = false }])
        dependsOn        = concat(local.obs_after_config, [{ containerName = "loki", condition = "START" }])
        logConfiguration = local.obs_log["grafana"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
    ],
    # 지표(Mimir). config/mimir.yaml 과 collector 의 metrics 파이프라인이 들어온 뒤 obs_metrics_enabled 로 켠다 (NV-431)
    var.obs_metrics_enabled ? [
      # 이미지 기본 사용자는 root 다. 데이터 디렉터리 소유자로 낮춰 돌린다
      {
        name      = "mimir"
        image     = local.obs_images.mimir
        essential = true
        memory    = 1536
        user      = local.obs_data_dirs["mimir"]
        command   = ["-config.file=/config/mimir.yaml", "-config.expand-env=true"]
        environment = [
          { name = "MIMIR_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.mimir_bucket.id },
          { name = "MIMIR_S3_REGION", value = var.aws_region },
          { name = "MIMIR_RETENTION", value = var.obs_retention.metrics },
        ]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "mimir-data", containerPath = "/data", readOnly = false }])
        dependsOn        = local.obs_after_config
        stopTimeout      = 120
        logConfiguration = local.obs_log["mimir"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
    ] : [],
    # NCP DB 지표. 읽기 전용 exporter 계정과 그 비밀이 생긴 뒤 obs_mysqld_exporter 로 켠다
    local.obs_mysqld_exporter ? [
      {
        name      = "mysqld-exporter"
        image     = local.obs_images.mysqld_exp
        essential = false
        memory    = 128
        command = [
          "--mysqld.address=${data.terraform_remote_state.database.outputs.db_address}:${data.terraform_remote_state.database.outputs.db_port}",
          "--mysqld.username=${var.obs_mysqld_exporter.username}",
          "--web.listen-address=:${local.obs_ports.mysqld_metrics}",
        ]
        secrets = [
          { name = "MYSQLD_EXPORTER_PASSWORD", valueFrom = var.obs_mysqld_exporter.secret_arn },
        ]
        readonlyRootFilesystem = true
        logConfiguration       = local.obs_log["mysqld-exporter"]
        linuxParameters        = local.obs_common.linuxParameters
        restartPolicy          = local.obs_common.restartPolicy
      },
    ] : [],
  )
}

# ── 설정 파일 ─────────────────────────────────────────────────
resource "aws_s3_object" "obs_config" {
  for_each = local.obs_config_files

  bucket       = local.obs_config_bucket
  key          = "${local.obs_config_prefix}/${each.value}"
  source       = "${path.module}/config/${each.value}"
  etag         = filemd5("${path.module}/config/${each.value}")
  content_type = endswith(each.value, ".json") ? "application/json" : "text/yaml"
}

# ── 태스크 ────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "obs" {
  #checkov:skip=CKV_AWS_158:컨테이너 로그다. 다른 서비스 로그 그룹과 같이 기본 암호화(AWS 관리)를 쓴다
  #checkov:skip=CKV_AWS_338:관측 스택 자체의 로그라 서비스 로그와 같은 보존 기간이면 된다
  name              = local.obs_log_group
  retention_in_days = var.obs_log_retention_days
}

resource "aws_ecs_task_definition" "obs" {
  family                   = local.obs_name
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = "2048"
  memory                   = tostring(var.obs_task_memory)
  execution_role_arn       = data.terraform_remote_state.iam.outputs.obs_execution_role_arn
  task_role_arn            = data.terraform_remote_state.iam.outputs.obs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode(local.obs_containers)

  # config-init 가 받은 설정을 나머지가 읽는다. 태스크마다 새로 만든다
  volume {
    name = "config"

    docker_volume_configuration {
      scope  = "task"
      driver = "local"
    }
  }

  # 데이터 EBS 의 디렉터리 (ecs 스택 obs.tf 의 부팅 스크립트가 만들고 소유자를 맞춘다)
  dynamic "volume" {
    for_each = local.obs_data_dirs

    content {
      name      = "${volume.key}-data"
      host_path = "${local.obs_mount_path}/${volume.key}"
    }
  }
}

resource "aws_ecs_service" "obs" {
  name            = local.obs_name
  cluster         = local.obs_cluster_arn
  task_definition = aws_ecs_task_definition.obs.arn
  desired_count   = 1

  enable_execute_command = true
  propagate_tags         = "SERVICE"

  capacity_provider_strategy {
    capacity_provider = data.terraform_remote_state.ecs.outputs.obs_capacity_provider_name
    base              = 1
    weight            = 1
  }

  # 한 호스트의 데이터 디렉터리를 두 태스크가 같이 쓰면 안 된다. 옛 태스크를 먼저 내린다 (배포 동안 obs 가 잠깐 빈다)
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [data.terraform_remote_state.ecs.outputs.obs_subnet_id]
    security_groups  = [data.terraform_remote_state.security.outputs.obs_security_group_id]
    assign_public_ip = false
  }

  # 앱은 otel.<네임스페이스>:4317(gRPC) · :4318(HTTP) 로 보낸다. 앱 태스크의 Service Connect 프록시가 이 태스크로 보낸다
  service_connect_configuration {
    enabled   = true
    namespace = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_arn

    # 앱 기본값(ecs 스택 otel.tf)은 HTTP 다
    service {
      port_name      = "otlp-http"
      discovery_name = "otel"

      client_alias {
        port     = local.obs_ports.otlp_http
        dns_name = "otel.${data.terraform_remote_state.ecs.outputs.service_discovery_namespace_name}"
      }
    }

    # gRPC 를 쓰는 쪽을 위해 따로 이름을 둔다. 한 이름에 포트 둘을 묶을 수 있는지 확인하지 않았다
    service {
      port_name      = "otlp-grpc"
      discovery_name = "otel-grpc"

      client_alias {
        port     = local.obs_ports.otlp_grpc
        dns_name = "otel-grpc.${data.terraform_remote_state.ecs.outputs.service_discovery_namespace_name}"
      }
    }
  }

  # 설정 파일이 먼저 올라가 있어야 새 태스크가 받는다
  depends_on = [aws_s3_object.obs_config]
}

# ── obs 자체 감시 (CloudWatch) ───────────────────────────────
# obs 가 죽으면 Grafana 경보도 같이 죽는다. 그래서 obs 자신은 CloudWatch 로 본다
resource "aws_cloudwatch_metric_alarm" "obs_no_task" {
  alarm_name          = "${local.obs_name}-no-tasks"
  alarm_description   = "Observability stack has no running task. Logs, traces and metrics are being dropped"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10 # 배포 때 옛 태스크를 먼저 내리므로 잠깐 0 이 된다
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = aws_ecs_service.obs.name
  }

  alarm_actions = [local.alerts_topic_arn]
  ok_actions    = [local.alerts_topic_arn]
}

# unlimited 모드라 크레딧이 바닥나도 느려지지 않고 초과분이 과금된다. 계속 바닥이면 인스턴스 종류를 올린다
resource "aws_cloudwatch_metric_alarm" "obs_cpu_credits" {
  alarm_name          = "${local.obs_name}-cpu-credits"
  alarm_description   = "Observability instance is out of CPU credits (surplus is charged). Consider a larger or non-burstable instance"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.obs_cpu_credit_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { AutoScalingGroupName = data.terraform_remote_state.ecs.outputs.obs_autoscaling_group_name }

  alarm_actions = [local.alerts_topic_arn]
}

data "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}
