# ---------------------------------------------------------------------------
# Edge: Route 53 -> CloudFront (+WAF) -> S3 frontend and /api/* -> API Gateway
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "edge" {
  provider = aws.us_east_1 # CLOUDFRONT scope only exists in us-east-1
  count    = var.enable_edge ? 1 : 0
  name     = "${local.name}-edge-acl"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        rule_action_override {
          name = "SizeRestrictions_BODY" # answers payloads can exceed 8 KB
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Change C7 (load-test finding B2): the Assignment 2 rule allowed 20,000 requests per 5 min
  # per IP. One exam hall of 3,000 students behind one campus NAT IP sends 30,000 autosaves
  # per 5 min, so WAF would have blocked the whole hall mid-exam. Now:
  #   - per signed-in user (Authorization header): 600 / 5 min (autosave needs 10)
  #   - per IP: 100,000 / 5 min, only as a flood backstop
  rule {
    name     = "rate-limit-per-user"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_per_user_limit
        aggregate_key_type = "CUSTOM_KEYS"
        custom_key {
          header {
            name = "authorization"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-user"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 4
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_per_ip_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-edge-acl"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  count                             = local.cdn ? 1 : 0
  name                              = "${local.name}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_acm_certificate" "edge" {
  provider          = aws.us_east_1 # CloudFront only reads certificates from us-east-1
  count             = var.enable_edge && !var.use_floci ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "main" {
  count               = local.cdn ? 1 : 0
  enabled             = true
  default_root_object = "index.html"
  aliases             = var.use_floci ? [] : [var.domain_name]
  web_acl_id          = aws_wafv2_web_acl.edge[0].arn
  price_class         = "PriceClass_200" # includes the India edge locations that serve Bhutan
  comment             = "${local.name} frontend + API"

  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[0].id
  }

  origin {
    origin_id   = "api"
    domain_name = replace(aws_apigatewayv2_api.main.api_endpoint, "/^https?:\\/\\//", "")
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader
  }

  # SPA routing
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  logging_config {
    bucket = aws_s3_bucket.logs.bucket_domain_name
    prefix = "cloudfront/"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.use_floci
    acm_certificate_arn            = var.use_floci ? null : aws_acm_certificate.edge[0].arn
    ssl_support_method             = var.use_floci ? null : "sni-only"
    minimum_protocol_version       = var.use_floci ? "TLSv1" : "TLSv1.2_2021"
  }
}

data "aws_iam_policy_document" "frontend_bucket" {
  count = local.cdn ? 1 : 0
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  count  = local.cdn ? 1 : 0
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket[0].json
}

resource "aws_route53_zone" "main" {
  count = var.enable_edge ? 1 : 0
  name  = var.domain_name
}

locals {
  cdn = var.enable_edge && var.enable_cdn
}

# Apex -> CloudFront (alias). Without the CDN (Floci) the API gets a CNAME instead.
resource "aws_route53_record" "apex" {
  count   = local.cdn ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_direct" {
  count   = var.enable_edge && !var.enable_cdn ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = "api.${var.domain_name}"
  type    = "CNAME"
  ttl     = 60
  records = [replace(aws_apigatewayv2_api.main.api_endpoint, "/^https?:\\/\\//", "")]
}
