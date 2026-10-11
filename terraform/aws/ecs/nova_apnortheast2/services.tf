# ─────────────────────────────────────────────────────────────
# 서비스 — application/<서비스>/service.yml 을 모듈에 넘긴다 (deploy: true 만)
#
# 모두 상시 구동한다. batch 도 앱 안의 @Scheduled 로 돌기 때문에 서비스로 띄우고,
# 같은 작업이 두 번 돌지 않게 singleton 으로 배포한다.
#
# 배포 방식 (service.yml 의 deployment)
#   blue_green : ECS 자체 Blue/Green. ALB 규칙마다 blue/green 타깃 그룹 한 쌍
#   rolling    : 롤링
#   singleton  : 옛 태스크를 먼저 내린다
# ─────────────────────────────────────────────────────────────

locals {
  # 요청 수 기반 스케일링 (타깃당 분당 요청 수). 롤링 서비스만 쓴다.
  # Blue/Green 은 배포마다 트래픽 받는 타깃 그룹이 바뀌어 지표 대상을 고정할 수 없으므로 CPU 로 늘린다
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

  # 다른 서비스가 호출하는 것만 Cloud Map 에 등록한다 (포트 없는 서비스 제외)
  enable_service_discovery       = each.value.port > 0
  service_discovery_namespace_id = aws_service_discovery_private_dns_namespace.this.id

  # max > min 일 때만 오토스케일링을 건다
  min_capacity         = each.value.min
  max_capacity         = each.value.max > each.value.min ? each.value.max : 0
  cpu_target           = each.value.cpu_target
  request_count_target = each.value.blue_green ? 0 : lookup(local.request_count_targets, each.key, 0)

  queue_backlog = each.value.backlog == null ? null : {
    queue_name      = local.queues[each.value.backlog.queue].name
    target_per_task = each.value.backlog.per_task
  }

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
      error_message = "DB 주소가 비어 있습니다. NCP 콘솔에서 Cloud DB for MySQL 의 Public 도메인을 켜고 ncp-database 를 다시 apply 하세요."
    }
  }
}
