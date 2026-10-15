# ─────────────────────────────────────────────────────────────
# scheduler — 배치 실행 (EventBridge Scheduler → ECS RunTask)
#
# 스케줄마다 태스크를 하나 띄우고 끝나면 내린다. 실행 중에만 요금이 붙는다.
#
# 실패 감지
#   RunTask 호출 실패(권한, 용량) → 재시도 후 DLQ → 경보
#   배치 코드 실패(종료코드 != 0) → ECS 태스크 종료 이벤트 → 경보
# ─────────────────────────────────────────────────────────────

locals {
  app_subnets = data.terraform_remote_state.vpc.outputs.app_subnet_ids
  batch_sg_id = data.terraform_remote_state.security.outputs.app_security_group_ids["batch"]
  cluster_arn = data.terraform_remote_state.ecs.outputs.cluster_arn
  # 리비전(:N)을 떼고 넘겨야 새 리비전이 등록됐을 때 최신 ACTIVE 리비전으로 실행한다.
  # batch 가 deploy: false 면 빈 값이다 (그때 스케줄이 있으면 아래 precondition 이 막는다)
  batch_taskdef = try(regex("^(.+):[0-9]+$", data.terraform_remote_state.ecs.outputs.batch_task_definition_arn)[0], "")
  role_arn      = data.terraform_remote_state.iam.outputs.scheduler_role_arn
  dlq_arn       = data.terraform_remote_state.sqs.outputs.scheduler_dlq.arn

  batch_container = "${local.name_prefix}-${local.services["batch"].name}"
}

resource "aws_scheduler_schedule_group" "this" {
  name = "${local.name_prefix}-batch"
}

resource "aws_scheduler_schedule" "job" {
  for_each = var.jobs

  lifecycle {
    precondition {
      condition     = local.batch_taskdef != ""
      error_message = "batch 태스크 정의가 없다. application/batch/service.yml 을 deploy: true 로 하고 ecs 를 먼저 apply 한다."
    }
  }

  name       = "${local.name_prefix}-${each.key}"
  group_name = aws_scheduler_schedule_group.this.name
  state      = each.value.enabled ? "ENABLED" : "DISABLED"

  description                  = each.value.description
  schedule_expression          = each.value.schedule
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF" # 만료 처리가 밀리면 안 되므로 정시에 실행한다
  }

  target {
    arn      = local.cluster_arn
    role_arn = local.role_arn

    ecs_parameters {
      task_definition_arn = local.batch_taskdef
      launch_type         = "FARGATE"
      task_count          = 1
      propagate_tags      = "TASK_DEFINITION"

      network_configuration {
        subnets          = local.app_subnets
        security_groups  = [local.batch_sg_id]
        assign_public_ip = false
      }
    }

    # 태스크 정의는 하나이고, 작업 종류는 컨테이너 인자로 구분한다.
    input = jsonencode({
      containerOverrides = [{
        name    = local.batch_container
        command = each.value.command
      }]
    })

    retry_policy {
      maximum_retry_attempts       = var.retry_attempts
      maximum_event_age_in_seconds = 3600
    }

    dead_letter_config {
      arn = local.dlq_arn
    }
  }
}
