# 이 서비스의 ALB 라우팅 — service.yml 의 routes 마다 타깃 그룹과 리스너 규칙.
# Blue/Green 이면 규칙마다 blue · green 타깃 그룹 한 쌍이다. ECS 가 새 버전을 green 에 띄우고
# 헬스체크가 통과하면 규칙 대상을 green 으로 바꾼다. 다음 배포에서는 역할이 뒤바뀐다.

locals {
  # "<순번>-<색>" -> 규칙 순번 (예: 0-blue, 0-green, 1-blue)
  target_groups = merge(
    { for i, r in var.routes : "${i}-blue" => i },
    var.blue_green ? { for i, r in var.routes : "${i}-green" => i } : {},
  )

  # aws_ecs_service 의 load_balancer 블록 (규칙 순서대로)
  load_balancers = [
    for i, r in var.routes : {
      target_group_arn           = aws_lb_target_group.this["${i}-blue"].arn
      alternate_target_group_arn = var.blue_green ? aws_lb_target_group.this["${i}-green"].arn : null
      production_listener_rule   = var.blue_green ? aws_lb_listener_rule.blue_green[tostring(i)].arn : null
    }
  ]
}

resource "aws_lb_target_group" "this" {
  for_each = local.target_groups

  name        = substr("${var.name}-${each.key}", 0, 32)
  port        = var.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # awsvpc 모드라 태스크 ENI 의 IP 가 타깃이 된다

  deregistration_delay = 30 # 배포 · 스케일인 때 지연을 줄인다

  # 넣을 때는 빠르게, 뺄 때는 신중하게. 새 태스크는 5초 × 2번(약 10초)이면 요청을 받는다.
  # 부하가 몰리면 정상 태스크도 readiness 응답이 몇 초씩 늦을 수 있어 25초(5번) 연속 실패해야 뺀다 —
  # 빨리 빼면 남은 태스크로 부하가 몰려 줄줄이 빠진다. readiness 는 앱 상태만 본다(DB · Redis 제외, be 기본값)
  health_check {
    enabled             = true
    port                = tostring(var.health.port) # 관리 포트가 있으면 그 포트의 readiness 를 본다
    path                = var.health.path
    matcher             = var.health.matcher
    interval            = 5 # ALB 최솟값
    timeout             = 4 # interval 보다 짧아야 한다
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = {
    Name    = "${var.service_key}-${each.key}"
    Service = var.discovery_name
  }
}

# 경로 기반 라우팅. 원본 확인 헤더가 없으면 규칙에 걸리지 않고 기본 동작(404)으로 끝난다
# 롤링 — 규칙 대상은 Terraform 이 관리한다
resource "aws_lb_listener_rule" "rolling" {
  for_each = var.blue_green ? {} : { for i, r in var.routes : tostring(i) => r }

  listener_arn = var.listener_arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["${each.key}-blue"].arn
  }

  condition {
    path_pattern {
      values = each.value.paths
    }
  }

  condition {
    http_header {
      http_header_name = var.origin_verify_header.name
      values           = [var.origin_verify_header.value]
    }
  }

  # 같은 경로를 메서드로 나눠 보낼 때 쓴다 (예: POST /api/v1/preorders 는 waitingroom, GET 은 preorder)
  dynamic "condition" {
    for_each = length(each.value.methods) > 0 ? [each.value.methods] : []

    content {
      http_request_method {
        values = condition.value
      }
    }
  }

  tags = { Service = var.discovery_name }

}

# Blue/Green — 배포 때 ECS 가 가중치를 바꾸므로 action 은 Terraform 이 되돌리지 않는다
resource "aws_lb_listener_rule" "blue_green" {
  for_each = var.blue_green ? { for i, r in var.routes : tostring(i) => r } : {}

  listener_arn = var.listener_arn
  priority     = each.value.priority

  # 두 타깃 그룹을 가중치로 함께 건다 (blue 100 · green 0). ECS 는 이 가중치를 바꿔 트래픽을 옮기고,
  # 테스트 규칙이 없으면 운영 규칙에 두 그룹이 다 있어야 서비스 설정을 받아 준다
  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.this["${each.key}-blue"].arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.this["${each.key}-green"].arn
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = each.value.paths
    }
  }

  condition {
    http_header {
      http_header_name = var.origin_verify_header.name
      values           = [var.origin_verify_header.value]
    }
  }

  # 같은 경로를 메서드로 나눠 보낼 때 쓴다 (예: POST /api/v1/preorders 는 waitingroom, GET 은 preorder)
  dynamic "condition" {
    for_each = length(each.value.methods) > 0 ? [each.value.methods] : []

    content {
      http_request_method {
        values = condition.value
      }
    }
  }

  tags = { Service = var.discovery_name }

  lifecycle {
    # Blue/Green 배포 때 ECS 가 가중치(blue ↔ green)를 바꾼다. 되돌리지 않게 무시한다
    ignore_changes = [action]
  }
}
