# 프런트는 Vercel 이 호스팅하므로 정적 파일 버킷은 없다.
#   upload : 사용자 업로드 이미지. 브라우저가 presigned URL 로 PUT 하고,
#            조회는 CloudFront(OAC)로만 한다. 버킷은 비공개
#   log    : ALB, CloudFront 액세스 로그
#
# upload 버킷의 CloudFront 읽기 정책은 배포 ARN 이 필요해서 cdn 스택에서 붙인다.

data "aws_caller_identity" "current" {}

locals {
  suffix  = var.bucket_suffix != "" ? var.bucket_suffix : data.aws_caller_identity.current.account_id
  buckets = ["upload", "log"]
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

resource "aws_s3_bucket_cors_configuration" "upload" {
  bucket = aws_s3_bucket.this["upload"].id

  # 조회는 CloudFront 로 하므로 PUT 만 연다
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.upload_cors_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
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
