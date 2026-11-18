# ---------------------------------------------------------------------------
# API Gateway HTTP API with Cognito JWT authorizer
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  description   = "Online exams and submissions API"

  cors_configuration {
    allow_origins = var.enable_edge && !var.use_floci ? ["https://${var.domain_name}"] : ["*"]
    allow_methods = ["GET", "POST", "PUT", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  # AWS: the "live" alias (carries provisioned concurrency). Floci cannot resolve alias-qualified ARNs.
  integration_uri        = var.use_floci ? aws_lambda_function.fn["api"].invoke_arn : aws_lambda_alias.api_live.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = var.use_floci ? 30000 : 10000
}

locals {
  routes = [
    "GET /health",
    "GET /exams/{examId}",
    "POST /exams/{examId}/attempts",
    "PUT /attempts/{attemptId}/answers",
    "POST /attempts/{attemptId}/submit",
    "POST /uploads",
    "GET /courses/{courseId}/submissions",
    "POST /exams/{examId}/results/release",
  ]
}

resource "aws_apigatewayv2_route" "routes" {
  for_each           = toset(local.routes)
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = each.value == "GET /health" || var.use_floci ? "NONE" : "JWT"
  authorizer_id      = each.value == "GET /health" || var.use_floci ? null : aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  provider    = aws.stage
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 5000 # 3,000 students opening an exam in the same minute
    throttling_rate_limit  = 2000
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId", route = "$context.routeKey", status = "$context.status",
      latency   = "$context.responseLatency", user = "$context.authorizer.claims.sub"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["api"].function_name
  qualifier     = var.use_floci ? null : aws_lambda_alias.api_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
