# 부하 시험(Grandis-2/nova-loadtest) 버킷. 공개 차단 · SSE-S3 는 main.tf 의 공통 리소스가 붙인다.
#   tokens/<시험 ID>/  토큰 발급기가 만든 시험 회원 토큰. 시험이 끝나면 컨트롤러가 바로 지운다
#   results/<시험 ID>/ k6 태스크별 요약(k6-<i>.json)과 컨트롤러의 plan · summary
#
# 수명주기는 접두사마다 건다. tokens/ 의 1일은 컨트롤러가 죽어 못 지운 토큰을 치우는 안전망이다(삭제가 하루쯤 늦을 수 있다).
# 버전 관리는 켜지 않는다. 켜면 지운 토큰이 이전 버전으로 남는다.

locals {
  # iam 스택(층 4)의 부하 시험 역할. obs 처럼 이름 규칙으로 ARN 을 만든다 (iam 이 s3 를 읽으므로 remote state 로 참조하면 순환한다)
  loadtest_role_arn = { for r in ["k6", "minter", "controller", "github-run"] : r => "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-loadtest-${r}" }

  # tokens/ 의 객체 작업 -> 허용할 역할. 토큰을 읽는 것은 k6 뿐이다
  loadtest_token_access = {
    Read   = { actions = ["s3:GetObject*"], roles = ["k6"] }
    Write  = { actions = ["s3:PutObject*"], roles = ["minter"] }
    Delete = { actions = ["s3:DeleteObject*"], roles = ["controller", "github-run"] } # github-run: 컨트롤러가 죽었을 때 뒷정리
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loadtest" {
  bucket = aws_s3_bucket.this["loadtest"].id

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
      days = var.loadtest_results_expiration_days
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
# 모든 주체를 거부한다. 허용(Allow)은 iam 스택의 각 역할 정책이 준다. 수명주기 삭제는 버킷 정책을 거치지 않는다.
data "aws_iam_policy_document" "loadtest" {
  dynamic "statement" {
    for_each = local.loadtest_token_access
    content {
      sid       = "DenyToken${statement.key}ExceptLoadtestRoles"
      effect    = "Deny"
      actions   = statement.value.actions
      resources = ["${aws_s3_bucket.this["loadtest"].arn}/tokens/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = [for r in statement.value.roles : local.loadtest_role_arn[r]]
      }
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this["loadtest"].arn, "${aws_s3_bucket.this["loadtest"].arn}/*"]

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
  bucket = aws_s3_bucket.this["loadtest"].id
  policy = data.aws_iam_policy_document.loadtest.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
