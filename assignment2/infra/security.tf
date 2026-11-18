# ---------------------------------------------------------------------------
# Encryption keys and secrets
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "data" {
  description             = "${local.name} data key (RDS, DynamoDB, S3, SQS, Secrets, logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db/master"
  description             = "PostgreSQL master credentials (rotated every 30 days in AWS)"
  kms_key_id              = aws_kms_key.data.arn
  recovery_window_in_days = var.use_floci ? 0 : 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "exams_admin"
    password = random_password.db.result
    engine   = "postgres"
    port     = 5432
    dbname   = "exams"
  })
}

# ---------------------------------------------------------------------------
# Authentication: Cognito user pool with role groups
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = var.use_floci ? "OFF" : "OPTIONAL" # Floci has no SetUserPoolMfaConfig

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 3
  }

  dynamic "software_token_mfa_configuration" {
    for_each = var.use_floci ? [] : [1]
    content {
      enabled = true
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true # accounts are provisioned by administrators
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name                          = "${local.name}-web"
  user_pool_id                  = aws_cognito_user_pool.main.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  access_token_validity         = 4 # hours - longer than the longest exam
  id_token_validity             = 4
  refresh_token_validity        = 1 # days
  prevent_user_existence_errors = "ENABLED"

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_group" "roles" {
  for_each     = toset(["students", "tutors", "admins"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Role-based access group: ${each.key}"
}
