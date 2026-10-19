# 프런트는 Vercel 이 호스팅하므로 정적 파일 버킷은 없다.
#   upload : 사용자 업로드 이미지. catalog 가 받아 버킷에 올리고(브라우저가 직접 PUT 하지 않아 CORS 도 없다),
#            조회는 CloudFront(OAC)로만 한다. 버킷은 비공개
#   log    : ALB, CloudFront 액세스 로그
#   loki   : 관측 스택(obs)의 Loki 청크 · 인덱스. 설정은 obs.tf
#   tempo  : 관측 스택의 Tempo 트레이스 블록
#   mimir  : 관측 스택의 Mimir 지표 블록 · 경보 규칙
#   obs-config : 관측 스택 설정 파일(monitoring 스택의 lgtm/). 태스크가 시작할 때 init 컨테이너가 받는다
#   loadtest : 부하 시험의 토큰(tokens/)과 결과(results/). 설정은 loadtest.tf
#
# upload 버킷의 정책(CloudFront 읽기 + 비TLS 요청 거부)은 cdn 스택이 붙인다. CloudFront 읽기 조건에 배포 ARN 이
# 필요한데 cdn 이 s3 에 의존하므로 여기서는 만들 수 없다. 버킷 정책은 하나뿐이라 여기서 따로 붙이면 서로 덮어쓴다.
# cdn 이 적용되기 전까지는 버킷이 비공개 · 업로드 권한 없음(uploads · upload_cleanup 인 서비스 없음) 상태라 노출 경로가 없다.

data "aws_caller_identity" "current" {}

locals {
  suffix  = var.bucket_suffix != "" ? var.bucket_suffix : data.aws_caller_identity.current.account_id
  buckets = ["upload", "log", "loki", "tempo", "mimir", "obs-config", "loadtest"]
}

resource "aws_s3_bucket" "this" {
  for_each = toset(local.buckets)

  bucket = "${local.name_prefix}-${each.value}-${local.suffix}"

  tags = {
    Name = "${local.name_prefix}-${each.value}"
    Role = each.value
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# 중단된 멀티파트 업로드 조각을 지운다
resource "aws_s3_bucket_lifecycle_configuration" "upload" {
  bucket = aws_s3_bucket.this["upload"].id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# CloudFront 표준 로그는 버킷 ACL 로 기록한다. 새 버킷 기본값(BucketOwnerEnforced)은
# ACL 이 꺼져 있어 CloudFront 로그 설정이 실패한다.
resource "aws_s3_bucket_ownership_controls" "log" {
  bucket = aws_s3_bucket.this["log"].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "log" {
  bucket = aws_s3_bucket.this["log"].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ALB 액세스 로그 권한. 2022년 8월 이전에 열린 리전(서울 포함)은 서비스 주체가 아니라
# 리전별 ELB 계정이 로그를 쓴다.
data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "log" {
  statement {
    sid     = "AllowALBLogDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }

    resources = ["${aws_s3_bucket.this["log"].arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this["log"].arn, "${aws_s3_bucket.this["log"].arn}/*"]

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

resource "aws_s3_bucket_policy" "log" {
  bucket = aws_s3_bucket.this["log"].id
  policy = data.aws_iam_policy_document.log.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
