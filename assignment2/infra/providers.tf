terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # Remote state in S3 with a DynamoDB lock table. Values come from
  # envs/<env>.backend.hcl (partial configuration) - see scripts/bootstrap-state.sh.
  backend "s3" {}
}

locals {
  floci_endpoint = var.floci_endpoint
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "DSO303-A2"
  }
}

provider "aws" {
  region = var.region

  # Floci (local AWS emulator) needs fake credentials, path-style S3 and endpoint overrides.
  access_key                  = var.use_floci ? "test" : null
  secret_key                  = var.use_floci ? "test" : null
  skip_credentials_validation = var.use_floci
  skip_metadata_api_check     = var.use_floci
  skip_requesting_account_id  = var.use_floci
  s3_use_path_style           = var.use_floci

  dynamic "endpoints" {
    for_each = var.use_floci ? [1] : []
    content {
      apigateway     = local.floci_endpoint
      apigatewayv2   = local.floci_endpoint
      backup         = local.floci_endpoint
      cloudfront     = local.floci_endpoint
      cloudtrail     = local.floci_endpoint
      cloudwatch     = local.floci_endpoint
      cloudwatchlogs = local.floci_endpoint
      cognitoidp     = local.floci_endpoint
      dynamodb       = local.floci_endpoint
      ec2            = local.floci_endpoint
      events         = local.floci_endpoint
      iam            = local.floci_endpoint
      kms            = local.floci_endpoint
      lambda         = local.floci_endpoint
      rds            = local.floci_endpoint
      route53        = local.floci_endpoint
      s3             = local.floci_endpoint
      secretsmanager = local.floci_endpoint
      ses            = local.floci_endpoint
      sns            = local.floci_endpoint
      sqs            = local.floci_endpoint
      ssm            = local.floci_endpoint
      sts            = local.floci_endpoint
      wafv2          = local.floci_endpoint
    }
  }

  default_tags {
    tags = local.tags
  }
}

# Used only by the API Gateway stage: Floci cannot tag HTTP API stages, so on Floci
# this provider sends no default tags. On AWS it is identical to the default provider.
provider "aws" {
  alias  = "stage"
  region = var.region

  access_key                  = var.use_floci ? "test" : null
  secret_key                  = var.use_floci ? "test" : null
  skip_credentials_validation = var.use_floci
  skip_metadata_api_check     = var.use_floci
  skip_requesting_account_id  = var.use_floci

  dynamic "endpoints" {
    for_each = var.use_floci ? [1] : []
    content {
      apigatewayv2 = local.floci_endpoint
      sts          = local.floci_endpoint
    }
  }

  default_tags {
    tags = var.use_floci ? {} : local.tags
  }
}
