# ---------------------------------------------------------------------------
# S3: frontend bucket, submissions bucket (lifecycle), access-log bucket
# ---------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  frontend_bucket    = "${local.name}-frontend-${random_id.suffix.hex}"
  submissions_bucket = "${local.name}-submissions-${random_id.suffix.hex}"
  logs_bucket        = "${local.name}-logs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "frontend" {
  bucket        = local.frontend_bucket
  force_destroy = true
}

resource "aws_s3_bucket" "submissions" {
  bucket        = local.submissions_bucket
  force_destroy = var.use_floci
}

resource "aws_s3_bucket" "logs" {
  bucket        = local.logs_bucket
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "all" {
  for_each                = { frontend = aws_s3_bucket.frontend.id, submissions = aws_s3_bucket.submissions.id, logs = aws_s3_bucket.logs.id }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "submissions" {
  bucket = aws_s3_bucket.submissions.id
  versioning_configuration {
    status = "Enabled" # an overwritten or deleted submission can always be recovered
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "submissions" {
  bucket = aws_s3_bucket.submissions.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle: hot for the semester, cheaper tiers afterwards, deleted after 5 years.
resource "aws_s3_bucket_lifecycle_configuration" "submissions" {
  bucket = aws_s3_bucket.submissions.id

  rule {
    id     = "submissions-retention-5y"
    status = "Enabled"
    filter {
      prefix = "submissions/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
    expiration {
      days = 365 * var.retention_years + 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "logs-1y"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
  }
}

# Browsers upload straight to S3 with a presigned PUT.
resource "aws_s3_bucket_cors_configuration" "submissions" {
  bucket = aws_s3_bucket.submissions.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.enable_edge && !var.use_floci ? ["https://${var.domain_name}"] : ["*"]
    allowed_headers = ["content-type", "x-amz-*"]
    max_age_seconds = 3000
  }
}

# Deny anything that is not TLS; enforce encryption in transit.
data "aws_iam_policy_document" "submissions_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.submissions.arn, "${aws_s3_bucket.submissions.arn}/*"]
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

resource "aws_s3_bucket_policy" "submissions" {
  count  = var.use_floci ? 0 : 1 # Floci serves plain HTTP locally
  bucket = aws_s3_bucket.submissions.id
  policy = data.aws_iam_policy_document.submissions_bucket.json
}

# New object in submissions/ -> SQS -> notifier Lambda
resource "aws_s3_bucket_notification" "submissions" {
  bucket = aws_s3_bucket.submissions.id

  queue {
    queue_arn     = aws_sqs_queue.uploads.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "submissions/"
  }

  depends_on = [aws_sqs_queue_policy.uploads]
}

# Frontend: built SPA
resource "aws_s3_object" "frontend" {
  for_each     = fileset("${path.module}/../app/frontend", "**")
  bucket       = aws_s3_bucket.frontend.id
  key          = each.value
  source       = "${path.module}/../app/frontend/${each.value}"
  etag         = filemd5("${path.module}/../app/frontend/${each.value}")
  content_type = lookup({ html = "text/html", js = "application/javascript", css = "text/css", json = "application/json" }, reverse(split(".", each.value))[0], "application/octet-stream")
}
