# ECS Blue/Green — 리스너 규칙 · 타깃 그룹 전환
# ECS 가 이 역할로 리스너 규칙 대상을 blue ↔ green 으로 바꾼다
data "aws_iam_policy_document" "ecs_lb_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_lb" {
  name               = "${local.name_prefix}-ecs-infrastructure-lb"
  assume_role_policy = data.aws_iam_policy_document.ecs_lb_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_lb" {
  role       = aws_iam_role.ecs_lb.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
