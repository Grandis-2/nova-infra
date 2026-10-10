# sops 용 KMS 키와 그 키를 쓰는 IAM 역할
#   common : 애플리케이션 비밀 (JWT 개인키, 카카오, 대기열 키 등)
#   secure : 인프라 자격증명 (GitHub 토큰, NCP 인증키 등)
#
# .sops.yaml 에 키 ARN 과 역할 ARN 을 함께 적어, sops 가 역할을 assume 해서 암복호화한다.
# 키 정책은 이 역할에만 사용 권한을 준다.
#
# 역할 신뢰 주체는 계정 루트라서, IAM 정책으로 assume 을 허용받은 주체만 쓸 수 있다.
#   Atlantis 태스크 역할 : atlantis-deploy 가 권한을 준다
#   관리자              : BreakGlassAdmin 으로 assume 한다
#   읽기 전용 역할       : 권한이 없다. 비밀을 쓰는 스택은 Atlantis 에서만 plan 할 수 있다

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  keys = {
    common = var.common_alias
    secure = var.secure_alias
  }
}

resource "aws_iam_role" "sops" {
  for_each = local.keys

  name        = "${var.role_name_prefix}-${each.key}"
  description = "Assumed to encrypt/decrypt sops files with the ${each.key} KMS key"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.root }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_kms_key" "sops" {
  for_each = local.keys

  description             = "KMS key for encrypt with sops the ${replace(replace(each.value, "-", " "), "_", " ")} secrets in ${var.region}."
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-${each.key}-1"
    Statement = [
      {
        Sid       = "Manage"
        Effect    = "Allow"
        Principal = { AWS = local.root }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "UseForSops"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.sops[each.key].arn }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "sops" {
  for_each = local.keys

  name          = "alias/${each.value}"
  target_key_id = aws_kms_key.sops[each.key].key_id
}
