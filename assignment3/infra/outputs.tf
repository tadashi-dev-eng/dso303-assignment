output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnets" {
  value = {
    data = { for s in aws_subnet.data : s.availability_zone => s.id }
  }
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.main.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.main.id
}

output "cloudfront_domain" {
  value = local.cdn ? aws_cloudfront_distribution.main[0].domain_name : null
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "db_cluster_arn" {
  value = local.db_arn
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "submissions_bucket" {
  value = aws_s3_bucket.submissions.id
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.id
}

output "attempts_table" {
  value = aws_dynamodb_table.attempts.name
}

output "submissions_table" {
  value = aws_dynamodb_table.submissions.name
}

output "queues" {
  value = merge({ for k, q in aws_sqs_queue.main : k => q.url }, { uploads = aws_sqs_queue.uploads.url })
}

output "lambda_functions" {
  value = { for k, f in aws_lambda_function.fn : k => f.function_name }
}

# URL clients should call. Floci serves HTTP APIs on <id>.execute-api.localhost.floci.io:4566.
output "api_url" {
  value = var.use_floci ? "http://${aws_apigatewayv2_api.main.id}.execute-api.localhost.floci.io:4566" : (local.cdn ? "https://${var.domain_name}/api" : aws_apigatewayv2_api.main.api_endpoint)
}
