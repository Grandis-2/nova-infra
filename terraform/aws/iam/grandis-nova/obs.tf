# 관측 호스트(obs) 인스턴스 역할 — Grandis-2/nova-observability 의 stack/compose.yaml 을 띄우는 EC2 (obs 스택)
#   SSM Core          세션 매니저 접속 · 포트 포워딩(Grafana)
#   Loki 버킷         청크 · 인덱스 읽기 · 쓰기, compactor 의 보존 기간 삭제
#   Grafana 비밀번호  부팅할 때 읽어 Grafana 에 파일로 넘긴다
#   스택 설정 파라미터 obs-deploy 가 배포할 커밋 · 버킷 이름 등을 읽는다 (obs 스택이 만든다)
#
# 역할 이름은 바꾸지 않는다. s3 스택의 Loki 버킷 정책이 이 이름의 역할만 객체에 접근하게 막아 두었다.
# 서비스 태스크 역할 · 실행 역할에는 이 권한을 주지 않는다.
locals {
  obs_name            = "${local.name_prefix}-obs"
  loki_bucket_arn     = data.terraform_remote_state.s3.outputs.loki_bucket.arn
  obs_stack_param_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/obs/stack-env"
}

resource "aws_iam_role" "obs" {
  name               = local.obs_name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "obs_ssm" {
  role       = aws_iam_role.obs.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "obs" {
  statement {
    sid       = "LokiBucketList"
    actions   = ["s3:ListBucket"]
    resources = [local.loki_bucket_arn]
  }

  statement {
    sid       = "LokiObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.loki_bucket_arn}/*"]
  }

  statement {
    sid       = "GrafanaAdminPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.secretsmanager.outputs.grafana_admin_secret_arn]
  }

  statement {
    sid       = "StackSettings"
    actions   = ["ssm:GetParameter"]
    resources = [local.obs_stack_param_arn]
  }
}

resource "aws_iam_role_policy" "obs" {
  name   = "obs-host"
  role   = aws_iam_role.obs.id
  policy = data.aws_iam_policy_document.obs.json
}

resource "aws_iam_instance_profile" "obs" {
  name = local.obs_name
  role = aws_iam_role.obs.name
}
