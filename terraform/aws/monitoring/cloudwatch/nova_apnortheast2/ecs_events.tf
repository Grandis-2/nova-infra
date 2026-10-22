# ─────────────────────────────────────────────────────────────
# ECS 이벤트 경보 — 태스크가 뜨지 못하거나 죽는 것을 사건으로 알린다
#
# Container Insights 를 끄면 "목표 대비 모자란 태스크 · 뜨는 중(Pending)" 수치가 없다. 대신 그 원인이 되는 사건을 받는다.
#   배포 실패       ECS Deployment State Change · SERVICE_DEPLOYMENT_FAILED (서킷 브레이커가 되돌림)
#   배치 · 설정 실패 ECS Service Action · SERVICE_TASK_PLACEMENT_FAILURE · SERVICE_TASK_CONFIGURATION_FAILURE (자리 · 이미지 · 비밀 · 역할)
#   태스크 죽음      ECS Task State Change · STOPPED 중 필수 컨테이너 종료 · 기동 실패 · 헬스체크 실패
#     배포 · 스케일 인으로 내린 태스크(ServiceSchedulerInitiated 중 헬스체크 실패가 아닌 것)와 Spot 회수는 뺀다.
#     배치 태스크(ecs 출력 batch_task_groups)는 main.tf 의 batch_failure 가 따로 본다.
# 태스크가 하나도 없는 상태는 서비스별 "태스크 0개" 경보(main.tf)가 본다.
# EventBridge → SNS 는 무료다. Chatbot 이 그릴 수 있게 사용자 정의 알림 형식으로 바꿔 보낸다.
# ─────────────────────────────────────────────────────────────

locals {
  ecs_cluster_arn = data.terraform_remote_state.ecs.outputs.cluster_arn
  # 배포 · 배치 실패는 관측 클러스터(obs · 게이트웨이 · 브라우저 수집기)도 본다. 태스크 죽음은 앱 서비스만 본다
  ecs_watched_cluster_arns = [local.ecs_cluster_arn, data.terraform_remote_state.ecs.outputs.observability_cluster_arn]
  # arn:aws:ecs:<리전>:<계정>:cluster/<이름> → 서비스 ARN 접두사 arn:aws:ecs:<리전>:<계정>:service/<이름>/
  ecs_service_arn_prefixes = [for arn in local.ecs_watched_cluster_arns : { prefix = "${replace(arn, ":cluster/", ":service/")}/" }]
  # 서비스 태스크만 본다. 단독 실행 태스크(group = family:<이름>)와 배치 서비스는 batch_failure 가 본다
  ecs_event_groups = [for key, name in local.service_names : "service:${name}" if !contains(local.batch_task_groups, "service:${name}")]

  ecs_event_rules = {
    deployment-failed = {
      description = "ECS service deployment failed and was rolled back"
      pattern = {
        source      = ["aws.ecs"]
        detail-type = ["ECS Deployment State Change"]
        resources   = local.ecs_service_arn_prefixes
        detail      = { eventName = ["SERVICE_DEPLOYMENT_FAILED"] }
      }
      paths    = { service = "$.resources[0]", reason = "$.detail.reason" }
      title    = "ECS deployment failed"
      template = "<service>: <reason>"
    }
    task-start-failed = {
      description = "ECS service cannot place or configure tasks"
      pattern = {
        source      = ["aws.ecs"]
        detail-type = ["ECS Service Action"]
        detail = {
          clusterArn = local.ecs_watched_cluster_arns
          eventName  = ["SERVICE_TASK_PLACEMENT_FAILURE", "SERVICE_TASK_CONFIGURATION_FAILURE"]
        }
      }
      paths    = { service = "$.resources[0]", event = "$.detail.eventName", reason = "$.detail.reason" }
      title    = "ECS tasks cannot start"
      template = "<service>: <event> <reason>"
    }
    task-died = {
      description = "ECS service task stopped abnormally (crash, start failure, health check)"
      pattern = {
        source      = ["aws.ecs"]
        detail-type = ["ECS Task State Change"]
        detail = {
          lastStatus = ["STOPPED"]
          clusterArn = [local.ecs_cluster_arn]
          group      = local.ecs_event_groups
          "$or" = [
            { stopCode = ["EssentialContainerExited", "TaskFailedToStart"] },
            { stoppedReason = [{ prefix = "Task failed ELB health checks" }, { prefix = "Task failed container health checks" }] },
          ]
        }
      }
      paths    = { group = "$.detail.group", code = "$.detail.stopCode", reason = "$.detail.stoppedReason" }
      title    = "ECS task stopped abnormally"
      template = "<group> (<code>): <reason>"
    }
  }
}

resource "aws_cloudwatch_event_rule" "ecs" {
  for_each = local.ecs_event_rules

  name          = "${local.name_prefix}-ecs-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "ecs" {
  for_each = local.ecs_event_rules

  rule      = aws_cloudwatch_event_rule.ecs[each.key].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = each.value.paths
    # jsonencode 는 < > 를 \u003c \u003e 로 바꾼다. 그러면 EventBridge 가 <자리> 를 채우지 못해 되돌린다
    input_template = replace(replace(jsonencode({ version = "1.0", source = "custom", content = { title = each.value.title, description = each.value.template } }), "\\u003c", "<"), "\\u003e", ">")
  }
}
