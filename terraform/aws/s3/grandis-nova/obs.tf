# 관측 스택(obs) 저장소 — Loki · Tempo · Mimir. 스택은 monitoring 스택의 ECS 태스크다 (NV-425).
# 공개 차단 · SSE-S3 는 main.tf 의 공통 리소스가 붙인다.
#
# 지우는 주체는 각 compactor 다 (로그 90일 · 트레이스 14일 · 지표는 Mimir 설정).
# 수명주기의 만료는 compactor 가 멈췄을 때를 위한 안전망이다.
# mimir 버킷에는 만료를 두지 않는다. 지표 블록과 함께 경보 규칙 · Alertmanager 설정이 들어 있어 날짜로 지우면 안 된다.

data "aws_partition" "current" {}

locals {
  # iam 스택(층 4)의 obs 역할. 이름 규칙으로 ARN 을 만든다 (iam 이 s3 를 읽으므로 remote state 로 참조하면 순환한다)
  obs_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-obs"

  # 버킷 키 -> 안전망 만료(일). null 이면 만료 없음
  obs_buckets = {
    loki  = var.loki_expiration_days
    tempo = var.tempo_expiration_days
    mimir = null
  }
}

# 버전 관리를 켜지 않는다. 켜면 compactor 가 지운 객체가 이전 버전으로 남아 보존 기간이 지켜지지 않는다
resource "aws_s3_bucket_versioning" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    id     = each.value != null ? "expire-safety-net" : "abort-multipart"
    status = "Enabled"

    filter {}

    dynamic "expiration" {
      for_each = each.value != null ? [each.value] : []
      content {
        days = expiration.value
      }
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.obs]
}

# 로그 · 트레이스에는 마스킹이 놓친 개인정보가 남을 수 있다. 계정 안의 다른 역할이 IAM 권한만으로 객체를 읽지 못하게
# obs 역할이 아닌 모든 주체의 객체 작업을 거부한다. 허용(Allow)은 iam 스택의 obs 역할 정책이 준다.
#
# Principal 에 역할을 적는 Allow 가 아니라 Principal "*" + aws:PrincipalArn 조건의 Deny 로 쓴다.
# S3 는 Principal 의 ARN 이 실제로 있는지 검사해 없으면 정책을 거부한다(MalformedPolicy: Invalid principal).
# 조건 값은 검사하지 않는 문자열이라 역할과 순서를 따지지 않는다.
# 버킷 설정(Terraform)은 객체 작업이 아니라 이 규칙에 걸리지 않는다.
data "aws_iam_policy_document" "obs" {
  for_each = local.obs_buckets

  statement {
    sid       = "DenyObjectAccessExceptObsHost"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
    resources = ["${aws_s3_bucket.this[each.key].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.obs_role_arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]

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

resource "aws_s3_bucket_policy" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.this[each.key].id
  policy   = data.aws_iam_policy_document.obs[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# loki 버킷 리소스는 처음에 단일 리소스로 만들었다 (nova-infra #13). 주소만 옮긴다
moved {
  from = aws_s3_bucket_versioning.loki
  to   = aws_s3_bucket_versioning.obs["loki"]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.loki
  to   = aws_s3_bucket_lifecycle_configuration.obs["loki"]
}

moved {
  from = aws_s3_bucket_policy.loki
  to   = aws_s3_bucket_policy.obs["loki"]
}

# ── obs-config 버킷 — 관측 스택 설정 파일 ─────────────────────────────
# monitoring 스택이 lgtm/ 을 올리고(aws_s3_object), obs 태스크의 init 컨테이너가 시작할 때 받는다.
# loki 버킷의 한 접두사로 두지 않는다. loki 버킷은 100일 만료 수명주기가 있어 바뀌지 않은 설정 파일이 지워진다.
#
# 버전 관리를 켠다. 설정을 잘못 올렸을 때 이전 버전으로 되돌릴 수 있게 한다. 지난 버전은 30일 뒤 지운다.
# 쓰기는 Terraform 실행 역할만, 읽기는 obs 역할과 Terraform 실행 역할만 한다.
resource "aws_s3_bucket_versioning" "obs_config" {
  bucket = aws_s3_bucket.this["obs-config"].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "obs_config" {
  bucket = aws_s3_bucket.this["obs-config"].id

  rule {
    id     = "noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.obs_config]
}

locals {
  # Terraform 실행 역할(Atlantis 의 TF_VAR_assume_role_arn). 로컬 plan 처럼 비어 있으면 넣지 않는다
  obs_config_writers = compact([var.assume_role_arn])
}

data "aws_iam_policy_document" "obs_config" {
  statement {
    sid       = "DenyReadExceptObsAndTerraform"
    effect    = "Deny"
    actions   = ["s3:GetObject*"]
    resources = ["${aws_s3_bucket.this["obs-config"].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat([local.obs_role_arn], local.obs_config_writers)
    }
  }

  dynamic "statement" {
    for_each = length(local.obs_config_writers) > 0 ? [1] : []

    content {
      sid       = "DenyWriteExceptTerraform"
      effect    = "Deny"
      actions   = ["s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
      resources = ["${aws_s3_bucket.this["obs-config"].arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = local.obs_config_writers
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this["obs-config"].arn, "${aws_s3_bucket.this["obs-config"].arn}/*"]

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

resource "aws_s3_bucket_policy" "obs_config" {
  bucket = aws_s3_bucket.this["obs-config"].id
  policy = data.aws_iam_policy_document.obs_config.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
