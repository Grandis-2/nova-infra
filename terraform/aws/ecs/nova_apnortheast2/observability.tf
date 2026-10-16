# ─────────────────────────────────────────────────────────────
# 관측 클러스터 — 관측 스택(obs · OTel 게이트웨이 · 브라우저 수집기)을 앱과 다른 클러스터에 둔다
#
# 클러스터는 요금이 없고, 실행 격리(Fargate · obs 전용 EC2)는 클러스터와 상관없이 이미 되어 있다.
# 나누는 것은 권한과 일괄 작업의 범위다. 앱 배포 역할은 앱 클러스터 조건만 받아 관측 서비스에 닿지 않고,
# 앱 클러스터 전체를 멈추거나 다시 만들어도 관측은 그대로 남는다.
# 서비스 디스커버리 네임스페이스는 앱과 같이 쓴다. Service Connect 는 같은 네임스페이스면 클러스터를 넘어 이어진다.
# ─────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "observability" {
  name = "${local.name_prefix}-observability"

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }

  tags = { Name = "${local.name_prefix}-observability" }
}
