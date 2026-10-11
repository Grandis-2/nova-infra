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

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# ── 서비스 디스커버리 ────────────────────────────────────────
# 내부 호출은 ALB 를 거치지 않는다. <서비스>.<네임스페이스> 이름으로 태스크 IP 를 바로 찾는다.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.namespace_name
  description = "Internal service discovery for ${local.name_prefix}"
  vpc         = local.vpc_id
}
