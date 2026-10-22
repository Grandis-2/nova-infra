# ─────────────────────────────────────────────────────────────
# scheduler — 단발 배치 실행 (EventBridge Scheduler → ECS RunTask)
#
# service.yml 에 schedule 이 있는 앱마다 스케줄 하나. ecs 스택은 그 앱의 태스크 정의만 만들고(서비스 없음),
# 여기서 정해진 시각에 태스크를 하나 띄운다. 태스크는 일을 마치면 종료하고, 실행 중에만 요금이 붙는다.
#
# 실패
#   RunTask 호출 실패(권한, 용량) → 재시도 뒤 scheduler DLQ (sqs 스택)
#   배치 코드 실패(종료 코드 != 0) → ECS 태스크 종료 이벤트
# ─────────────────────────────────────────────────────────────

locals {
  app_subnets = data.terraform_remote_state.vpc.outputs.app_subnet_ids
  app_sg_ids  = data.terraform_remote_state.security.outputs.app_security_group_ids
  cluster_arn = data.terraform_remote_state.ecs.outputs.cluster_arn
  # 리비전(:N)을 떼고 넘긴다. 배포로 새 리비전이 등록돼도 최신 ACTIVE 리비전으로 띄운다.
  # ecs 를 아직 apply 하지 않아 출력이 없으면 빈 맵 — 아래 precondition 이 원인을 알린다
  task_families = {
    for k, arn in try(data.terraform_remote_state.ecs.outputs.scheduled_task_definition_arns, {}) : k => regex("^(.+):[0-9]+$", arn)[0]
  }
  role_arn = data.terraform_remote_state.iam.outputs.scheduler_role_arn
  dlq_arn  = data.terraform_remote_state.sqs.outputs.scheduler_dlq.arn
}

resource "aws_scheduler_schedule_group" "this" {
  name = "${local.name_prefix}-batch"
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.scheduled_services

  lifecycle {
    precondition {
      condition     = contains(keys(local.task_families), each.key)
      error_message = "${each.key} 의 태스크 정의가 ecs 스택 출력에 없다. ecs 를 먼저 apply 한 뒤 다시 plan 한다."
    }
  }

  name                         = "${local.name_prefix}-${each.value.name}"
  group_name                   = aws_scheduler_schedule_group.this.name
  schedule_expression          = each.value.schedule
  schedule_expression_timezone = "Asia/Seoul"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.cluster_arn
    role_arn = local.role_arn

    ecs_parameters {
      task_definition_arn = lookup(local.task_families, each.key, "")
      task_count          = 1
      propagate_tags      = "TASK_DEFINITION"

      # launch_type 은 용량 공급자와 함께 쓸 수 없어 비운다. 회수되면 그날은 건너뛰고 다음 날 다시 돈다
      capacity_provider_strategy {
        capacity_provider = "FARGATE_SPOT"
        weight            = 1
      }

      network_configuration {
        subnets          = local.app_subnets
        security_groups  = [local.app_sg_ids[each.key]]
        assign_public_ip = false
      }
    }

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }

    dead_letter_config {
      arn = local.dlq_arn
    }
  }
}
