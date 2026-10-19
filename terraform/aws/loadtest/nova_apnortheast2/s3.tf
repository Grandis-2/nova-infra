# 토큰 · 결과 버킷
#   tokens/<시험 ID>/  발급기가 만든 시험 회원 토큰. 시험이 끝나면 컨트롤러가 바로 지운다
#   results/<시험 ID>/ k6 태스크별 요약(k6-<i>.json)과 컨트롤러의 plan · summary
#
# 수명주기는 접두사마다 건다. tokens/ 의 1일은 컨트롤러가 죽어 못 지운 토큰을 치우는 안전망이다(삭제가 하루쯤 늦을 수 있다).
# 버전 관리는 켜지 않는다. 켜면 지운 토큰이 이전 버전으로 남는다.
resource "aws_s3_bucket" "loadtest" {
  bucket = "${local.loadtest_name}-${local.account_id}"

  tags = { Name = local.loadtest_name }
}

resource "aws_s3_bucket_public_access_block" "loadtest" {
  bucket = aws_s3_bucket.loadtest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loadtest" {
  bucket = aws_s3_bucket.loadtest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loadtest" {
  bucket = aws_s3_bucket.loadtest.id

  rule {
    id     = "expire-tokens"
    status = "Enabled"

    filter {
      prefix = "tokens/"
    }

    expiration {
      days = 1
    }
  }

  rule {
    id     = "expire-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    expiration {
      days = var.results_expiration_days
    }
  }

  rule {
    id     = "abort-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# tokens/ 는 서명된 시험 회원 토큰이다. 계정 안의 다른 역할이 IAM 권한만으로 읽거나 바꾸지 못하게, 작업마다 정한 역할이 아닌
# 모든 주체를 거부한다. 허용(Allow)은 iam.tf 의 각 역할 정책이 준다. 수명주기 삭제는 버킷 정책을 거치지 않는다.
locals {
  # tokens/ 의 객체 작업 -> 허용할 역할. 토큰을 읽는 것은 k6 뿐이다
  token_access = {
    Read   = { actions = ["s3:GetObject*"], roles = [aws_iam_role.task["k6"].arn] }
    Write  = { actions = ["s3:PutObject*"], roles = [aws_iam_role.task["minter"].arn] }
    Delete = { actions = ["s3:DeleteObject*"], roles = [aws_iam_role.task["controller"].arn, aws_iam_role.github["run"].arn] } # github-run: 컨트롤러가 죽었을 때 뒷정리
  }
}

data "aws_iam_policy_document" "loadtest_bucket" {
  dynamic "statement" {
    for_each = local.token_access
    content {
      sid       = "DenyToken${statement.key}ExceptLoadtestRoles"
      effect    = "Deny"
      actions   = statement.value.actions
      resources = ["${aws_s3_bucket.loadtest.arn}/tokens/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = statement.value.roles
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.loadtest.arn, "${aws_s3_bucket.loadtest.arn}/*"]

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

resource "aws_s3_bucket_policy" "loadtest" {
  bucket = aws_s3_bucket.loadtest.id
  policy = data.aws_iam_policy_document.loadtest_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.loadtest]
}
