# loki 버킷 — 관측 호스트(obs)의 Loki 가 청크 · 인덱스를 둔다 (Grandis-2/nova-observability).
# 공개 차단 · SSE-S3 는 main.tf 의 공통 리소스가 붙인다.
#
# 지우는 주체는 Loki compactor 다 (보존 90일). 버킷 수명주기의 만료는 compactor 가 멈췄을 때를 위한 안전망이다.

data "aws_partition" "current" {}

locals {
  # iam 스택의 obs 역할. 이름 규칙으로 ARN 을 만든다 (iam 이 s3 를 읽으므로 remote state 로 참조하면 순환한다).
  # 역할이 아직 없어도 조건 값은 문자열이라 정책은 만들어진다. 그 사이에는 누구도 객체를 읽고 쓰지 못한다
  obs_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-obs"
}

# 버전 관리를 켜지 않는다. 켜면 compactor 가 지운 객체가 이전 버전으로 남아 보존 기간이 지켜지지 않는다
resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.this["loki"].id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.this["loki"].id

  rule {
    id     = "expire-safety-net"
    status = "Enabled"

    filter {}

    expiration {
      days = var.loki_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.loki]
}

# 로그에는 마스킹이 놓친 개인정보가 남을 수 있다. 계정 안의 다른 역할이 IAM 권한만으로 객체를 읽지 못하게
# 객체 작업은 obs 역할만 허용한다. 버킷 설정(Terraform)은 객체 작업이 아니라 이 규칙에 걸리지 않는다.
data "aws_iam_policy_document" "loki" {
  statement {
    sid       = "DenyObjectAccessExceptObsHost"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
    resources = ["${aws_s3_bucket.this["loki"].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [local.obs_role_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this["loki"].arn, "${aws_s3_bucket.this["loki"].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "loki" {
  bucket = aws_s3_bucket.this["loki"].id
  policy = data.aws_iam_policy_document.loki.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
