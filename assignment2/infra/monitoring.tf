# ---------------------------------------------------------------------------
# Monitoring: CloudWatch alarms -> SNS, dashboard, CloudTrail
# ---------------------------------------------------------------------------
locals {
  alarms = {
    api-5xx = {
      namespace = "AWS/ApiGateway", metric = "5xx", stat = "Sum", threshold = 25, period = 60
      dims      = { ApiId = aws_apigatewayv2_api.main.id }
      desc      = "API returning server errors during an exam"
    }
    api-latency-p95 = {
      namespace = "AWS/ApiGateway", metric = "Latency", stat = "p95", threshold = 1500, period = 60
      dims      = { ApiId = aws_apigatewayv2_api.main.id }
      desc      = "Autosave slower than 1.5 s at p95"
    }
    lambda-throttles = {
      namespace = "AWS/Lambda", metric = "Throttles", stat = "Sum", threshold = 1, period = 60
      dims      = { FunctionName = aws_lambda_function.fn["api"].function_name }
      desc      = "API Lambda hit its concurrency limit"
    }
    marking-dlq = {
      namespace = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum", threshold = 1, period = 300
      dims      = { QueueName = aws_sqs_queue.dlq["marking"].name }
      desc      = "Attempts that could not be auto-marked"
    }
    uploads-dlq = {
      namespace = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum", threshold = 1, period = 300
      dims      = { QueueName = aws_sqs_queue.dlq["uploads"].name }
      desc      = "Upload notifications that failed"
    }
    marking-backlog-age = {
      namespace = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", stat = "Maximum", threshold = 900, period = 300
      dims      = { QueueName = aws_sqs_queue.main["marking"].name }
      desc      = "Marking backlog older than 15 minutes"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alarms" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.stat == "p95" ? null : each.value.stat
  extended_statistic  = each.value.stat == "p95" ? "p95" : null
  period              = each.value.period
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = each.value.dims
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  count               = var.enable_rds ? 1 : 0
  alarm_name          = "${local.name}-aurora-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.main[0].cluster_identifier }
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  count          = var.use_floci ? 0 : 1 # Floci has no PutDashboard
  dashboard_name = "${local.name}-exam-day"
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title   = "API requests / 5xx", region = var.region, stat = "Sum", period = 60
        metrics = [["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id], [".", "5xx", ".", "."]]
      } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title   = "API Lambda concurrency / throttles", region = var.region, stat = "Maximum", period = 60
        metrics = [["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.fn["api"].function_name], [".", "Throttles", ".", "."]]
      } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title   = "Autosave writes (DynamoDB)", region = var.region, stat = "Sum", period = 60
        metrics = [["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.attempts.name]]
      } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title   = "Queue depth", region = var.region, stat = "Maximum", period = 60
        metrics = [for k, q in merge(aws_sqs_queue.main, { uploads = aws_sqs_queue.uploads }) : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q.name]]
      } },
    ]
  })
}

resource "aws_cloudtrail" "main" {
  count                         = var.use_floci ? 0 : 1
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.data.arn
}
