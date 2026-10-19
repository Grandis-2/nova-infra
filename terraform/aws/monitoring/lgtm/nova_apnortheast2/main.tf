# ─────────────────────────────────────────────────────────────
# lgtm — 관측 스택 (LGTM on ECS, NV-425). CloudWatch 경보 · 대시보드는 monitoring/cloudwatch 스택이다.
#
# 앱 태스크의 OTel 에이전트 ──OTLP──▶ OTel 게이트웨이(gateway.tf, 별도 서비스)
#   ──▶ 이 태스크 하나: loki(로그) · tempo(트레이스) · mimir(지표) ─▶ S3 (Service Connect loki · tempo-otlp · mimir)
#                       grafana(조회 · 경보 → SNS → Chatbot → Slack), mysqld_exporter(선택)
#                       otel-collector(긁기 전용: LGTM 자체 · mysqld · obs 호스트 → mimir)
#   앱의 프로파일 ──▶ pyroscope.<네임스페이스>:4040 (Service Connect) ▶ pyroscope-ingest(4041, 올리기만) ▶ pyroscope(데이터 EBS, 7일)
#
#   설정   : config/ 를 obs-config 버킷에 올리고(아래 aws_s3_object), config-init 컨테이너가 태스크 시작 때 받는다.
#            파일 내용의 해시가 작업 정의에 들어가므로 설정을 고치면 apply 가 곧 재배포다.
#   실행   : ecs 스택의 obs 용량 공급자(EC2 1대). 데이터 디렉터리는 그 인스턴스의 데이터 EBS 를 bind mount 한다.
#            한 호스트의 디렉터리를 쓰므로 옛 태스크를 먼저 내리고 새 태스크를 띄운다(최소 0 · 최대 100%).
#   접속   : https://grafana.<도메인> — Cognito 로그인 뒤 Grafana 도 같은 풀로 OAuth 로그인한다(alb.tf, NV-517).
#            역할은 Cognito 그룹으로 정한다(grafana-admin → Admin, grafana-editor → Editor, 그 밖 → Viewer).
#            비상용 admin 은 /login?disableAutoLogin 에서 로그인한다. ECS Exec 포트 포워딩도 그대로 된다.
#
#     aws ssm start-session --target ecs:<클러스터>_<태스크 ID>_<grafana 런타임 ID> \
#       --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
#
# 한 태스크라 컨테이너가 localhost 를 같이 쓴다. 포트가 겹치면 뒤에 뜬 컨테이너가 죽는다 — 아래 obs_ports 가 기준이다.
# ─────────────────────────────────────────────────────────────

locals {
  obs_name = "${local.name_prefix}-obs"

  # 관측 클러스터(ecs 스택 observability.tf). obs 용량 공급자도 이 클러스터에 붙어 있다
  obs_cluster_arn  = data.terraform_remote_state.ecs.outputs.observability_cluster_arn
  obs_cluster_name = data.terraform_remote_state.ecs.outputs.observability_cluster_name
  obs_mount_path   = data.terraform_remote_state.ecs.outputs.obs_data_mount_path
  obs_data_dirs    = data.terraform_remote_state.ecs.outputs.obs_data_dirs # 디렉터리 -> uid:gid

  obs_config_bucket = data.terraform_remote_state.s3.outputs.obs_config_bucket.id
  obs_config_prefix = "lgtm"

  # config/ 의 설정 파일. 문서(README)는 올리지 않는다
  obs_config_files = toset([
    for f in fileset("${path.module}/config", "**") : f
    if !endswith(f, ".md")
  ])
  obs_config_hash = sha256(join("", [for f in sort(tolist(local.obs_config_files)) : "${f}:${filesha256("${path.module}/config/${f}")}"]))

  # 태스크 안 localhost 포트. config/ 의 설정 파일과 같아야 한다
  obs_ports = {
    otlp_grpc      = 4317 # 게이트웨이 수신(gateway.tf, 앱이 보낸다)
    otlp_http      = 4318 # 게이트웨이 수신
    loki_http      = 3100
    tempo_http     = 3200
    tempo_otlp     = 14317 # 게이트웨이 → tempo (OTLP gRPC). 기본값 4317 은 게이트웨이와 헷갈려 쓰지 않는다
    mimir_http     = 9009
    grafana        = 3000
    mysqld_metrics = 9104
    pyroscope      = 4040 # 태스크 안(Grafana · Collector)에서만. gRPC 9094 · raft 9099 · memberlist 7948 은 config/pyroscope.yaml
    pyroscope_in   = 4041 # 앱이 닿는 수신 전용 프록시(config/pyroscope-ingest.nginx.conf). obs 보안 그룹이 이 포트만 연다
  }

  # 이미지는 태그와 다이제스트로 고정한다 (linux/arm64 · linux/amd64 매니페스트)
  obs_images = {
    aws_cli        = "amazon/aws-cli:2.37.12@sha256:ce44b800602264c12298bbf3399055a4cefdb9ed4a098abe564afe26e7071bce"
    otel_collector = "otel/opentelemetry-collector-contrib:0.162.0@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6"
    loki           = "grafana/loki:3.7.8@sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193"
    tempo          = "grafana/tempo:2.10.8@sha256:f0561deb1c68ec44d6e6e7e4487f30106c4e5e768642077695b37958b105812a"
    mimir          = "grafana/mimir:3.2.2@sha256:04068a0a838b6efe9449a04c1d6acd74c7438ac6073dfcbb99c29892647525e3"
    grafana        = "grafana/grafana:12.4.12@sha256:83be3e511ede559bee80e2215bb1987cb1246075461cb961beb515b0341e7aea"
    mysqld_exp     = "prom/mysqld-exporter:v0.20.0@sha256:abed8dac117b4ae5b70757f988e44795935b9a72c3b58d720c67ba688f8cb79e"
    pyroscope      = "grafana/pyroscope:2.4.0@sha256:b7e62699a27463aa3533efe3f88c320da594da495731fd6eabca6f44f92cdd7b"
    nginx          = "nginxinc/nginx-unprivileged:1.29-alpine@sha256:0c79d56aee561a1d81c63f00eee5fb5fe29279560cdc55e91425133104c7fbe6"
  }

  obs_log_group = "/ecs/${local.obs_name}"

  # 모든 컨테이너 공통: 리눅스 권한을 모두 버리고(1024 위 포트만 쓴다), 죽으면 태스크를 내리지 않고 그 컨테이너만 다시 띄운다
  # 컨테이너 메모리 한도(MiB). 인스턴스 t4g.medium 이 ECS 에 등록하는 메모리(약 3.7 GiB) 안에서 나눈다.
  # 7일 최대 RSS(2026-10-16) 의 1.4~2.5배: tempo 770 · mimir 405 · grafana 328 · loki 204 · pyroscope 165 · mysqld 19
  # Go 프로세스는 한도의 90% 를 GOMEMLIMIT 로 줘서 한도에 다가가면 GC 를 더 돌려 OOM 종료 대신 버티게 한다
  obs_memory = {
    config-init      = 96
    otel-collector   = 192
    loki             = 512
    tempo            = 1152
    mimir            = 640
    grafana          = 448
    mysqld-exporter  = 48
    pyroscope        = 256
    pyroscope-ingest = 32
  }
  obs_gomemlimit = { for k, v in local.obs_memory : k => { name = "GOMEMLIMIT", value = "${floor(v * 0.9)}MiB" } }

  obs_common = {
    # add = [] 는 AWS 가 저장할 때 채우는 기본값이다. 적지 않으면 plan 마다 차이로 보여 작업 정의를 다시 만든다(obs 재배포)
    linuxParameters = { capabilities = { add = [], drop = ["ALL"] } }
    restartPolicy   = { enabled = true, restartAttemptPeriod = 60 }
  }

  obs_log = { for c in ["config-init", "otel-collector", "loki", "tempo", "mimir", "grafana", "mysqld-exporter", "pyroscope", "pyroscope-ingest"] : c => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = local.obs_log_group
      awslogs-region        = var.aws_region
      awslogs-stream-prefix = c
    }
  } }

  obs_after_config = [{ containerName = "config-init", condition = "SUCCESS" }]
  obs_config_mount = [{ sourceVolume = "config", containerPath = "/config", readOnly = true }]

  obs_mysqld_exporter = var.obs_mysqld_exporter_enabled

  # 프로파일(NV-540). 데이터 디렉터리는 ecs 스택이 만든다(obs_data_dirs 의 pyroscope). 그 스택이 먼저 적용돼 있어야 컨테이너를 띄운다
  obs_pyroscope = contains(keys(local.obs_data_dirs), "pyroscope")

  # mysqld_exporter 수집기는 DB 플랫폼이 주는 권한에 맞춘다(var.obs_mysql_platform)
  #   공통: performance_schema 는 SELECT 만 있으면 읽힌다(ncp 의 READ 는 모든 테이블 SELECT)
  #        perf_schema.eventsstatements — 다이제스트(SQL 형태)별 실행 수 · 시간 · 검사 행. 상위 SQL 표. 최근 하루 동안 본 것 중 시간 순 100개
  #        perf_schema.memory_events    — mysqld 내부 메모리 사용(이벤트별)
  #   ncp: 계정이 READ 뿐이라 PROCESS · REPLICATION CLIENT 가 필요한 기본 수집기를 끈다(켜 두면 긁을 때마다 오류를 남긴다).
  #        slave_status(REPLICATION CLIENT, 복제도 없다) · info_schema.innodb_cmp/cmpmem(PROCESS) · info_schema.query_response_time(Percona 전용)
  #   rds: 계정에 PROCESS · REPLICATION CLIENT 를 주고 아래를 더 켠다
  #        info_schema.processlist      — 상태 · 사용자별 연결과 실행 시간(어느 서비스 계정이 연결을 쥐고 있나, 오래 도는 쿼리)
  #        info_schema.innodb_metrics   — 교착 상태 · 잠금 대기 시간 초과
  #        performance_schema 는 RDS 파라미터 그룹에서 켜져 있어야 한다(정적 값이라 바꾸면 재부팅)
  obs_mysqld_perf_schema = [
    "--collect.perf_schema.eventsstatements",
    "--collect.perf_schema.eventsstatements.limit=100",
    "--collect.perf_schema.memory_events",
  ]
  obs_mysqld_collectors = {
    ncp = concat(local.obs_mysqld_perf_schema, [
      "--no-collect.slave_status",
      "--no-collect.info_schema.innodb_cmp",
      "--no-collect.info_schema.innodb_cmpmem",
      "--no-collect.info_schema.query_response_time",
    ])
    rds = concat(local.obs_mysqld_perf_schema, [
      "--no-collect.info_schema.query_response_time",
      "--collect.info_schema.processlist",
      "--no-collect.info_schema.processlist.processes_by_host",
      "--collect.info_schema.innodb_metrics",
    ])
  }

  # 경보 토픽은 monitoring/cloudwatch 스택이 만든다 (Chatbot → Slack 이 이미 구독)
  alerts_topic_arn = data.aws_sns_topic.alerts.arn

  obs_containers = concat(
    [
      # 설정 파일을 받는다. 끝나면 내려간다(essential=false). 나머지는 이것이 성공해야 뜬다
      {
        name      = "config-init"
        image     = local.obs_images.aws_cli
        essential = false
        memory    = local.obs_memory["config-init"]
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
        # 긁기 · hostmetrics 만 한다. memory_limiter 는 이 안에서 160 MiB
        memory  = local.obs_memory["otel-collector"]
        command = ["--config=/config/collector.yaml"]
        environment = [
          { name = "MIMIR_OTLP_ENDPOINT", value = "http://localhost:${local.obs_ports.mimir_http}/otlp" },
          { name = "MYSQLD_EXPORTER_TARGET", value = local.obs_mysqld_exporter ? "localhost:${local.obs_ports.mysqld_metrics}" : "" },
          { name = "PYROSCOPE_TARGET", value = local.obs_pyroscope ? "localhost:${local.obs_ports.pyroscope}" : "" },
          { name = "OBS_DATA_MOUNT_PATH", value = local.obs_mount_path },
        ]
        # hostmetrics 가 호스트의 /proc · 마운트 정보를 읽는다(읽기 전용). 컨테이너는 UID 10001 · 권한 없음이라 누구나 읽을 수 있는 파일만 본다
        mountPoints            = concat(local.obs_config_mount, [{ sourceVolume = "hostfs", containerPath = "/hostfs", readOnly = true }])
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
        memory    = local.obs_memory["loki"]
        user      = local.obs_data_dirs["loki"]
        command   = ["-config.file=/config/loki.yaml", "-config.expand-env=true"]
        environment = [
          { name = "LOKI_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.loki_bucket.id },
          { name = "LOKI_S3_REGION", value = var.aws_region },
          { name = "LOKI_RETENTION_PERIOD", value = var.obs_retention.logs },
          local.obs_gomemlimit["loki"],
        ]
        # 게이트웨이(gateway.tf)가 Service Connect loki 로 보낸다
        portMappings     = [{ name = "loki-http", containerPort = local.obs_ports.loki_http, protocol = "tcp", appProtocol = "http" }]
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
        memory    = local.obs_memory["tempo"]
        user      = local.obs_data_dirs["tempo"]
        command   = ["-config.file=/config/tempo.yaml", "-config.expand-env=true"]
        environment = [
          { name = "TEMPO_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.tempo_bucket.id },
          { name = "TEMPO_S3_REGION", value = var.aws_region },
          { name = "TEMPO_RETENTION", value = var.obs_retention.traces },
          local.obs_gomemlimit["tempo"],
        ]
        # 게이트웨이가 Service Connect tempo-otlp 로 보낸다(OTLP gRPC)
        portMappings     = [{ name = "tempo-otlp", containerPort = local.obs_ports.tempo_otlp, protocol = "tcp", appProtocol = "grpc" }]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "tempo-data", containerPath = "/var/tempo", readOnly = false }])
        dependsOn        = local.obs_after_config
        stopTimeout      = 120
        logConfiguration = local.obs_log["tempo"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
      # 이미지 기본 사용자는 root 다. 데이터 디렉터리 소유자로 낮춰 돌린다(activity tracker 파일은 config/mimir.yaml 에서 /data 로 옮겼다)
      {
        name      = "mimir"
        image     = local.obs_images.mimir
        essential = true
        memory    = local.obs_memory["mimir"]
        user      = local.obs_data_dirs["mimir"]
        command   = ["-config.file=/config/mimir.yaml", "-config.expand-env=true"]
        environment = [
          { name = "MIMIR_S3_BUCKET", value = data.terraform_remote_state.s3.outputs.mimir_bucket.id },
          { name = "MIMIR_S3_REGION", value = var.aws_region },
          { name = "MIMIR_RETENTION", value = var.obs_retention.metrics },
          local.obs_gomemlimit["mimir"],
        ]
        # 게이트웨이가 Service Connect mimir 로 보낸다(OTLP HTTP)
        portMappings     = [{ name = "mimir-http", containerPort = local.obs_ports.mimir_http, protocol = "tcp", appProtocol = "http" }]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "mimir-data", containerPath = "/data", readOnly = false }])
        dependsOn        = local.obs_after_config
        stopTimeout      = 120
        logConfiguration = local.obs_log["mimir"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
      {
        name      = "grafana"
        image     = local.obs_images.grafana
        essential = true
        memory    = local.obs_memory["grafana"]
        user      = local.obs_data_dirs["grafana"]
        environment = [
          { name = "GF_PATHS_PROVISIONING", value = "/config/grafana/provisioning" },
          local.obs_gomemlimit["grafana"],
          # 로그인하면 개요 대시보드부터 본다(config/grafana/dashboards)
          { name = "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH", value = "/config/grafana/dashboards/01 Overview/overview.json" },
          { name = "GF_SERVER_ROOT_URL", value = local.grafana_url },
          { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "false" },
          # Cognito OAuth (alb.tf). ALB 에서 이미 로그인했으므로 Cognito 가 비밀번호를 다시 묻지 않고 돌려보낸다
          { name = "GF_AUTH_GENERIC_OAUTH_ENABLED", value = "true" },
          { name = "GF_AUTH_GENERIC_OAUTH_NAME", value = "Cognito" },
          { name = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID", value = local.cognito.grafana_client_id },
          { name = "GF_AUTH_GENERIC_OAUTH_SCOPES", value = "openid email profile" },
          { name = "GF_AUTH_GENERIC_OAUTH_AUTH_URL", value = "${local.cognito.auth_base_url}/oauth2/authorize" },
          { name = "GF_AUTH_GENERIC_OAUTH_TOKEN_URL", value = "${local.cognito.auth_base_url}/oauth2/token" },
          { name = "GF_AUTH_GENERIC_OAUTH_API_URL", value = "${local.cognito.auth_base_url}/oauth2/userInfo" },
          { name = "GF_AUTH_GENERIC_OAUTH_USE_PKCE", value = "true" },
          { name = "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP", value = "true" }, # 풀에 있는 사람만 오므로 첫 로그인 때 Grafana 사용자를 만든다
          { name = "GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN", value = "true" },
          { name = "GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH", value = "email" },
          # ID 토큰의 cognito:groups. 그룹이 없으면 Viewer. 로그인할 때마다 다시 맞춘다
          { name = "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH", value = "contains(\"cognito:groups\" || `[]`, 'grafana-admin') && 'Admin' || contains(\"cognito:groups\" || `[]`, 'grafana-editor') && 'Editor' || 'Viewer'" },
          { name = "GF_USERS_ALLOW_SIGN_UP", value = "false" },
          { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
          { name = "GF_SECURITY_DISABLE_GRAVATAR", value = "true" },
          { name = "GF_ANALYTICS_REPORTING_ENABLED", value = "false" },
          { name = "GF_ANALYTICS_CHECK_FOR_UPDATES", value = "false" },
          { name = "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES", value = "false" },
          { name = "GF_NEWS_NEWS_FEED_ENABLED", value = "false" },
          { name = "GF_PLUGINS_PLUGIN_ADMIN_ENABLED", value = "false" },
          # Drilldown 앱(로그 · 트레이스 · 지표 · 프로파일)은 기동 때 grafana.com 에서 받는다. 버전을 고정해 재배포마다 바뀌지 않게 한다
          { name = "GF_PLUGINS_PREINSTALL", value = "grafana-exploretraces-app@2.2.1,grafana-lokiexplore-app@2.6.0,grafana-metricsdrilldown-app@2.5.1,grafana-pyroscope-app@2.3.1" },
          { name = "LOKI_URL", value = "http://localhost:${local.obs_ports.loki_http}" },
          { name = "TEMPO_URL", value = "http://localhost:${local.obs_ports.tempo_http}" },
          { name = "PYROSCOPE_URL", value = "http://localhost:${local.obs_ports.pyroscope}" },
          { name = "MIMIR_URL", value = "http://localhost:${local.obs_ports.mimir_http}/prometheus" },
          { name = "SNS_TOPIC_ARN", value = local.alerts_topic_arn },
          { name = "AWS_REGION", value = var.aws_region },
        ]
        # 최초 기동 때만 admin 에 쓰인다. 이미 있는 admin 의 비밀번호 교체는 config/README.md
        secrets = [
          { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = data.terraform_remote_state.secretsmanager.outputs.grafana_admin_secret_arn },
          { name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET", valueFrom = local.cognito.grafana_client_secret_arn },
        ]
        portMappings = [
          { name = "grafana", containerPort = local.obs_ports.grafana, protocol = "tcp", appProtocol = "http" },
        ]
        mountPoints      = concat(local.obs_config_mount, [{ sourceVolume = "grafana-data", containerPath = "/var/lib/grafana", readOnly = false }])
        dependsOn        = concat(local.obs_after_config, [{ containerName = "loki", condition = "START" }])
        logConfiguration = local.obs_log["grafana"]
        linuxParameters  = local.obs_common.linuxParameters
        restartPolicy    = local.obs_common.restartPolicy
      },
    ],
    # DB 지표. 대상 · 계정 · 비밀은 database 원격 상태의 출력(db_address · db_port · exporter_username · exporter_secret_arn)을 쓴다.
    # 어느 플랫폼이든 이 네 출력을 내면 된다. 켜는 수집기는 위 obs_mysqld_collectors
    # 언제나 남는 것: mysql_up, SHOW GLOBAL STATUS(연결 · 스레드 · 쿼리 · InnoDB 버퍼 풀 · 행 잠금 등), SHOW GLOBAL VARIABLES(max_connections 등)
    # TLS: 앱(JDBC sslMode=REQUIRED)과 같이 암호화는 하고 인증서는 검증하지 않는다(--tls.insecure-skip-verify → DSN tls=skip-verify)
    local.obs_mysqld_exporter ? [
      {
        name      = "mysqld-exporter"
        image     = local.obs_images.mysqld_exp
        essential = false
        memory    = local.obs_memory["mysqld-exporter"]
        command = concat([
          "--mysqld.address=${data.terraform_remote_state.database.outputs.db_address}:${data.terraform_remote_state.database.outputs.db_port}",
          "--mysqld.username=${data.terraform_remote_state.database.outputs.exporter_username}",
          "--tls.insecure-skip-verify",
          "--web.listen-address=:${local.obs_ports.mysqld_metrics}",
        ], local.obs_mysqld_collectors[var.obs_mysql_platform])
        secrets = [
          # 비밀은 JSON(username · password · host · port)이다. password 키만 넣는다
          { name = "MYSQLD_EXPORTER_PASSWORD", valueFrom = "${data.terraform_remote_state.database.outputs.exporter_secret_arn}:password::" },
        ]
        readonlyRootFilesystem = true
        logConfiguration       = local.obs_log["mysqld-exporter"]
        linuxParameters        = local.obs_common.linuxParameters
        restartPolicy          = local.obs_common.restartPolicy
      },
    ] : [],
    # 프로파일. 같은 태스크의 다른 컨테이너와 겹치지 않는 포트는 config/pyroscope.yaml 머리말에 있다
    local.obs_pyroscope ? [
      {
        name      = "pyroscope"
        image     = local.obs_images.pyroscope
        essential = false
        memory    = local.obs_memory["pyroscope"]
        user      = local.obs_data_dirs["pyroscope"]
        command   = ["-config.file=/config/pyroscope.yaml"]
        # 압축 작업 임시 디렉터리(/tmp)를 데이터 볼륨으로 돌린다. 루트 파일시스템을 읽기 전용으로 두기 위해서다
        environment            = [{ name = "TMPDIR", value = "/data" }, local.obs_gomemlimit["pyroscope"]]
        mountPoints            = concat(local.obs_config_mount, [{ sourceVolume = "pyroscope-data", containerPath = "/data", readOnly = false }])
        dependsOn              = local.obs_after_config
        stopTimeout            = 60
        readonlyRootFilesystem = true
        logConfiguration       = local.obs_log["pyroscope"]
        linuxParameters        = local.obs_common.linuxParameters
        restartPolicy          = local.obs_common.restartPolicy
      },
    ] : [],
    local.obs_pyroscope ? [
      # 앱이 닿는 쪽. 프로파일 올리기(POST /ingest)만 Pyroscope 로 넘기고 조회 API 는 403 이다.
      # Pyroscope 4040 은 조회 API 도 내므로 앱에 직접 열지 않는다(열면 Grafana 인증 없이 다른 서비스 프로파일을 읽는다)
      {
        name                   = "pyroscope-ingest"
        image                  = local.obs_images.nginx
        essential              = false
        memory                 = local.obs_memory["pyroscope-ingest"]
        command                = ["nginx", "-c", "/config/pyroscope-ingest.nginx.conf", "-g", "daemon off;"]
        portMappings           = [{ name = "pyroscope", containerPort = local.obs_ports.pyroscope_in, protocol = "tcp", appProtocol = "http" }]
        mountPoints            = local.obs_config_mount
        dependsOn              = concat(local.obs_after_config, [{ containerName = "pyroscope", condition = "START" }])
        readonlyRootFilesystem = true
        logConfiguration       = local.obs_log["pyroscope-ingest"]
        # nginx 의 pid · 임시 파일은 /tmp 에 쓴다. 루트는 읽기 전용이라 메모리 tmpfs 를 붙인다
        linuxParameters = merge(local.obs_common.linuxParameters, { tmpfs = [{ containerPath = "/tmp", size = 16 }] })
        restartPolicy   = local.obs_common.restartPolicy
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

  # obs 호스트 지표(Collector 의 hostmetrics). 컨테이너에는 읽기 전용으로 붙인다
  volume {
    name      = "hostfs"
    host_path = "/"
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

  # Grafana 공개 (alb.tf). 대상이 등록되기 전에 헬스체크로 태스크를 내리지 않게 기동 시간을 준다
  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = local.obs_ports.grafana
  }
  health_check_grace_period_seconds = 300

  network_configuration {
    subnets          = [data.terraform_remote_state.ecs.outputs.obs_subnet_id]
    security_groups  = [data.terraform_remote_state.security.outputs.obs_security_group_id]
    assign_public_ip = false
  }

  # Service Connect 로 내놓는 것: 게이트웨이가 보내는 loki · tempo-otlp · mimir, 앱이 프로파일을 보내는 pyroscope
  service_connect_configuration {
    enabled   = true
    namespace = data.terraform_remote_state.ecs.outputs.service_discovery_namespace_arn

    # 게이트웨이(gateway.tf)가 보내는 곳. obs SG 는 이 포트들을 게이트웨이 SG 에만 연다(앱은 별칭이 풀려도 닿지 못한다)
    # 예외로 Mimir 9009 는 부하 시험 컨트롤러 SG 에도 연다. 컨트롤러는 별칭이 아니라 obs 태스크 IP 로 직접 조회한다(terraform/aws/loadtest)
    dynamic "service" {
      for_each = local.gateway_enabled ? {
        loki         = { port_name = "loki-http", port = local.obs_ports.loki_http }
        "tempo-otlp" = { port_name = "tempo-otlp", port = local.obs_ports.tempo_otlp }
        mimir        = { port_name = "mimir-http", port = local.obs_ports.mimir_http }
      } : {}

      content {
        port_name      = service.value.port_name
        discovery_name = service.key

        client_alias {
          port     = service.value.port
          dns_name = "${service.key}.${data.terraform_remote_state.ecs.outputs.service_discovery_namespace_name}"
        }
      }
    }

    # 앱의 프로파일 수신(service.yml 에 profiling: true 인 서비스가 보낸다). 별칭 포트 4040 → 수신 전용 프록시 4041
    dynamic "service" {
      for_each = local.obs_pyroscope ? [1] : []

      content {
        port_name      = "pyroscope"
        discovery_name = "pyroscope"

        client_alias {
          port     = local.obs_ports.pyroscope
          dns_name = "pyroscope.${data.terraform_remote_state.ecs.outputs.service_discovery_namespace_name}"
        }
      }
    }
  }

  # 설정 파일이 먼저 올라가 있어야 새 태스크가 받는다. 대상 그룹은 리스너 규칙에 묶인 뒤에 서비스에 붙일 수 있다
  depends_on = [aws_s3_object.obs_config, aws_lb_listener_rule.grafana]
}

# ── obs 자체 감시 (CloudWatch) ───────────────────────────────
# obs 가 죽으면 Grafana 경보도 같이 죽는다. 그래서 obs 자신은 CloudWatch 로 본다
resource "aws_cloudwatch_metric_alarm" "obs_no_task" {
  alarm_name        = "${local.obs_name}-no-tasks"
  alarm_description = "Observability stack has no running task. Dashboards and Grafana alerts are down, the OTel gateway is queueing"
  # AWS/ECS 의 무료 태스크 수 지표. Container Insights 를 쓰지 않는다
  namespace           = "AWS/ECS"
  metric_name         = "LiveTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10 # 배포 때 옛 태스크를 먼저 내리므로 잠깐 0 이 된다
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = local.obs_cluster_name
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
