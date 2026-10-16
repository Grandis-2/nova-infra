resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }

  tags = { Name = local.name_prefix }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  # obs 용량 공급자는 관측 클러스터에 붙는다(observability.tf)
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# ── 서비스 디스커버리 ────────────────────────────────────────
# 내부 호출은 ALB 를 거치지 않는다. Service Connect 가 이 네임스페이스에 서비스를 등록하고,
# 각 태스크의 프록시가 <서비스>.<네임스페이스> 별칭을 상대 태스크로 보낸다.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.namespace_name
  description = "Internal service discovery for ${local.name_prefix}"
  vpc         = local.vpc_id
}
