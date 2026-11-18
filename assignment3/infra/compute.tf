# ---------------------------------------------------------------------------
# Lambda functions: api (sync), marker (SQS), notifier (SQS)
# ---------------------------------------------------------------------------
# Each function zip = its own folder + the shared Data API helper (app/shared/db.mjs).
data "archive_file" "fn" {
  for_each    = toset(["api", "marker", "notifier"])
  type        = "zip"
  output_path = "${path.module}/.build/${each.key}.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/../app/${each.key}", "*.mjs")
    content {
      filename = source.value
      content  = file("${path.module}/../app/${each.key}/${source.value}")
    }
  }

  source {
    filename = "db.mjs"
    content  = file("${path.module}/../app/shared/db.mjs")
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  for_each           = toset(["api", "marker", "notifier"])
  name               = "${local.name}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Logs and X-Ray only: the functions no longer attach ENIs to a VPC (change C3).
resource "aws_iam_role_policy_attachment" "basic" {
  for_each   = aws_iam_role.fn
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  for_each   = aws_iam_role.fn
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

locals {
  db_arn = var.enable_rds ? aws_rds_cluster.main[0].arn : "arn:aws:rds:${var.region}:${data.aws_caller_identity.current.account_id}:cluster:none"

  common_statements = [
    { actions = ["rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement"], resources = [local.db_arn] },
    { actions = ["secretsmanager:GetSecretValue"], resources = [aws_secretsmanager_secret.db.arn] },
    { actions = ["kms:Decrypt", "kms:GenerateDataKey"], resources = [aws_kms_key.data.arn] },
  ]

  fn_statements = {
    api = concat(local.common_statements, [
      { actions = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:GetItem"], resources = [aws_dynamodb_table.attempts.arn] },
      { actions = ["dynamodb:Query"], resources = ["${aws_dynamodb_table.submissions.arn}", "${aws_dynamodb_table.submissions.arn}/index/*"] },
      { actions = ["s3:PutObject"], resources = ["${aws_s3_bucket.submissions.arn}/submissions/*"] },
      { actions = ["sqs:SendMessage"], resources = [aws_sqs_queue.main["marking"].arn, aws_sqs_queue.main["notify"].arn] },
    ])
    marker = concat(local.common_statements, [
      { actions = ["dynamodb:Query"], resources = [aws_dynamodb_table.attempts.arn] },
      { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], resources = [aws_sqs_queue.main["marking"].arn] },
    ])
    notifier = concat(local.common_statements, [
      { actions = ["dynamodb:PutItem"], resources = [aws_dynamodb_table.submissions.arn] },
      { actions = ["s3:GetObject", "s3:GetObjectAttributes"], resources = ["${aws_s3_bucket.submissions.arn}/submissions/*"] },
      { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], resources = [aws_sqs_queue.main["notify"].arn, aws_sqs_queue.uploads.arn] },
      { actions = ["ses:SendEmail"], resources = ["*"] },
    ])
  }

  fn_env = {
    DB_CLUSTER_ARN    = local.db_arn
    DB_SECRET_ARN     = aws_secretsmanager_secret.db.arn
    DB_NAME           = "exams"
    ATTEMPTS_TABLE    = aws_dynamodb_table.attempts.name
    SUBMISSIONS_TABLE = aws_dynamodb_table.submissions.name
    SUBMISSIONS_BKT   = aws_s3_bucket.submissions.id
    MARKING_QUEUE_URL = aws_sqs_queue.main["marking"].url
    NOTIFY_QUEUE_URL  = aws_sqs_queue.main["notify"].url
    SENDER_EMAIL      = var.notification_sender
    MAX_UPLOAD_BYTES  = tostring(50 * 1024 * 1024)
    # Change C8: per-instance exam/question cache (0 = off, the Assignment 2 behaviour).
    EXAM_CACHE_SECONDS = tostring(var.exam_cache_seconds)
    # Inside Floci's Lambda containers the SDK must call back to the emulator.
    AWS_ENDPOINT_URL = var.use_floci ? "http://floci:4566" : ""
  }
}

data "aws_iam_policy_document" "fn" {
  for_each = local.fn_statements
  dynamic "statement" {
    for_each = each.value
    content {
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.fn_statements
  name     = "${local.name}-${each.key}-policy"
  role     = aws_iam_role.fn[each.key].id
  policy   = data.aws_iam_policy_document.fn[each.key].json
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = toset(["api", "marker", "notifier"])
  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = var.log_retention_days # 90 -> 30 days (change C6)
}

resource "aws_lambda_function" "fn" {
  for_each         = toset(["api", "marker", "notifier"])
  function_name    = "${local.name}-${each.key}"
  role             = aws_iam_role.fn[each.key].arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.fn[each.key].output_path
  source_code_hash = data.archive_file.fn[each.key].output_base64sha256
  memory_size      = each.key == "api" ? 512 : 256
  timeout          = each.key == "api" ? (var.use_floci ? 30 : 10) : 60 # Floci cold starts take 10-17 s on a laptop
  publish          = true

  reserved_concurrent_executions = each.key == "api" ? var.lambda_reserved_concurrency : 50

  environment {
    variables = { for k, v in local.fn_env : k => v if v != "" }
  }

  # No vpc_config (change C3). Every dependency is an AWS API reached over HTTPS: DynamoDB, S3,
  # SQS, SES and Aurora through the RDS Data API. Lambda runs the functions in all AZs of the
  # Region, so there is no NAT gateway or ENI to lose with an AZ, and no NAT bill.

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

resource "aws_lambda_alias" "api_live" {
  name             = "live"
  function_name    = aws_lambda_function.fn["api"].function_name
  function_version = aws_lambda_function.fn["api"].version
}

# Warm capacity during exam windows (switched on by scheduled scaling, 0 in Floci).
resource "aws_lambda_provisioned_concurrency_config" "api" {
  count                             = var.lambda_provisioned_concurrency > 0 ? 1 : 0
  function_name                     = aws_lambda_function.fn["api"].function_name
  qualifier                         = aws_lambda_alias.api_live.name
  provisioned_concurrent_executions = var.lambda_provisioned_concurrency
}

resource "aws_lambda_event_source_mapping" "marker" {
  event_source_arn                   = aws_sqs_queue.main["marking"].arn
  function_name                      = aws_lambda_function.fn["marker"].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "notifier_notify" {
  event_source_arn        = aws_sqs_queue.main["notify"].arn
  function_name           = aws_lambda_function.fn["notifier"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "notifier_uploads" {
  event_source_arn        = aws_sqs_queue.uploads.arn
  function_name           = aws_lambda_function.fn["notifier"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}
