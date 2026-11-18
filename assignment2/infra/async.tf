# ---------------------------------------------------------------------------
# Asynchronous processing: SQS queues (+DLQs), SNS alarm topic, SES identity
# ---------------------------------------------------------------------------
locals {
  queues = {
    marking = { visibility = 120, desc = "Submitted attempts waiting for MCQ auto-marking" }
    notify  = { visibility = 60, desc = "Result-release emails to students" }
    uploads = { visibility = 60, desc = "S3 ObjectCreated events for assignment uploads" }
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = local.queues
  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate failures
  kms_master_key_id         = var.use_floci ? null : aws_kms_key.data.id
}

resource "aws_sqs_queue" "main" {
  for_each                   = { for k, v in local.queues : k => v if k != "uploads" }
  name                       = "${local.name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility
  message_retention_seconds  = 345600 # 4 days
  kms_master_key_id          = var.use_floci ? null : aws_kms_key.data.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

# Uploads queue uses SQS-managed encryption because S3 event delivery cannot use a customer KMS key
# without extra key-policy grants; still encrypted at rest.
resource "aws_sqs_queue" "uploads" {
  name                       = "${local.name}-uploads"
  visibility_timeout_seconds = local.queues.uploads.visibility
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["uploads"].arn
    maxReceiveCount     = 5
  })
}

data "aws_iam_policy_document" "uploads_queue" {
  statement {
    sid       = "AllowS3Events"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.uploads.arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.submissions.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "uploads" {
  queue_url = aws_sqs_queue.uploads.id
  policy    = data.aws_iam_policy_document.uploads_queue.json
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = var.use_floci ? null : "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_ses_email_identity" "sender" {
  email = var.notification_sender
}
