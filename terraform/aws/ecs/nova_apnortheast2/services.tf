# ─────────────────────────────────────────────────────────────
# 서비스 — application/<서비스>/service.yml 을 모듈에 넘긴다 (deploy: true 만)
#
# 상시 구동한다. 정합성 검사(batch-reconciliation)도 앱 안의 @Scheduled 로 돌기 때문에 서비스로 띄우고,
# 같은 작업이 두 번 돌지 않게 singleton 으로 배포한다.
# service.yml 에 schedule 이 있으면 서비스 없이 태스크 정의만 만들고 scheduler 스택이 RunTask 로 띄운다.
#
# 배포 방식 (service.yml 의 deployment)
#   blue_green : ECS 자체 Blue/Green. ALB 규칙마다 blue/green 타깃 그룹 한 쌍
#   rolling    : 롤링
#   singleton  : 옛 태스크를 먼저 내린다
# ─────────────────────────────────────────────────────────────

locals {
  # 경보 토픽 — monitoring/cloudwatch 스택이 만든다(Chatbot → Slack 구독). 그 스택은 ecs 출력을 읽으므로
  # remote state 대신 이름 규칙으로 ARN 을 만든다: 클러스터 ARN 의 파티션 · 리전 · 계정 + <name_prefix>-alerts
  _cluster_arn_parts = split(":", aws_ecs_cluster.this.arn)
  alerts_topic_arn   = "arn:${local._cluster_arn_parts[1]}:sns:${local._cluster_arn_parts[3]}:${local._cluster_arn_parts[4]}:${local.name_prefix}-alerts"

  # 요청 수 기반 스케일링 (타깃당 분당 요청 수). 롤링 서비스만 쓴다.
  # Blue/Green 은 배포마다 트래픽 받는 타깃 그룹이 바뀌어 대상 추적의 지표 대상을 고정할 수 없으므로 CPU 로 늘린다.
  # 요청 수로 바로 늘리기는 모듈 burst.tf 가 blue · green 대상 그룹을 더해 본다 (service.yml 의 scaling.requests_per_task)
  request_count_targets = {}
}

module "service" {
  source = "../_modules/service"

  for_each = local.deployed_services

  name           = "${local.name_prefix}-${each.value.name}"
  discovery_name = each.value.name
  cluster_arn    = aws_ecs_cluster.this.arn
  cluster_name   = aws_ecs_cluster.this.name

  image            = local.service_images[each.key] # image.tf (service.yml 의 image_tag)
  cpu              = each.value.cpu
  memory           = each.value.memory
  cpu_architecture = var.cpu_architecture
  port             = each.value.port
  extra_port       = each.value.mgmt_port

  desired_count  = each.value.desired
  use_spot       = each.value.spot
  on_demand_base = var.spot_on_demand_base
  singleton      = each.value.singleton
  create_service = each.value.schedule == null # schedule 이 있으면 태스크 정의만 만든다 (scheduler 스택이 띄운다)

  subnet_ids         = local.app_subnets
  security_group_ids = [local.app_sg_ids[each.key]]

  execution_role_arn = local.exec_role_arn
  task_role_arn      = local.task_role_arns[each.key]

  environment = local.service_env[each.key]
  secrets     = local.service_secrets[each.key]

  log_retention_days = var.log_retention_days

  # ALB 라우팅 (service.yml 의 routes · health). 타깃 그룹 · 규칙은 모듈이 만든다
  service_key          = each.key
  routes               = each.value.routes
  health               = each.value.health
  vpc_id               = local.vpc_id
  listener_arn         = local.routing_listener_arn
  alb_arn_suffix       = aws_lb.this.arn_suffix
  origin_verify_header = { name = local.origin_verify_header, value = random_password.origin_verify.result }
  blue_green           = each.value.blue_green
  lb_role_arn          = each.value.blue_green ? local.ecs_lb_role_arn : ""

  # 서비스 간 호출. 포트가 있는 서비스만 <이름>.<네임스페이스> 로 내놓는다 (locals.tf 의 서비스 주소와 같아야 한다)
  service_connect_namespace = aws_service_discovery_private_dns_namespace.this.arn
  service_connect_dns_name  = each.value.port > 0 ? "${each.value.name}.${var.namespace_name}" : ""

  # max > min 일 때만 오토스케일링을 건다
  min_capacity         = each.value.min
  max_capacity         = each.value.max > each.value.min ? each.value.max : 0
  cpu_target           = each.value.cpu_target
  request_count_target = each.value.blue_green ? 0 : lookup(local.request_count_targets, each.key, 0)

  # 순간 폭주 증설 (모듈 burst.tf). 먼저 늘리고 경보 토픽(Slack)에 알린다
  burst_requests_per_task = each.value.requests_per_task
  alarm_topic_arn         = local.alerts_topic_arn

  queue_backlog = each.value.backlog == null ? null : {
    queue_names     = [for q in each.value.backlog.queues : local.queues[q].name]
    target_per_task = each.value.backlog.per_task
  }

  # ALB 가 없는 서비스(컨슈머)는 health 를 컨테이너 헬스체크로 쓴다. 이미지에 curl · wget 이 없어 bash 로 직접 묻는다.
  # 상태 줄의 두 번째 칸(코드)만 본다 — Tomcat 은 이유 문구 없이 "HTTP/1.1 200" 을 보낸다. 끝의 \r 은 지운다
  health_check_command = length(each.value.routes) == 0 && each.value.health != null ? [
    "CMD", "bash", "-c",
    "exec 3<>/dev/tcp/127.0.0.1/${each.value.health.port} && printf 'GET ${each.value.health.path} HTTP/1.0\\r\\n\\r\\n' >&3 && read -r _ code _ <&3 && [ \"$${code%$'\\r'}\" = 200 ]",
  ] : []
  stop_timeout = each.value.stop_timeout

  tags = {
    Service = each.value.name
    Context = each.key
  }
}

# NCP DB 의 Public 도메인은 콘솔에서 켜야 생긴다. 주소가 비면 모든 서비스가
# 재시작만 반복하므로 apply 를 먼저 막는다.
resource "terraform_data" "db_ready" {
  lifecycle {
    precondition {
      condition     = local.db_address != ""
      error_message = "DB 주소가 비어 있습니다. rds 스택 출력(db_address)을 확인하세요."
    }
  }
}
