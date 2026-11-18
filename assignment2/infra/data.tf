# ---------------------------------------------------------------------------
# Relational system of record: Aurora PostgreSQL, writer in AZ-a, reader in AZ-b
# Users, courses, exam definitions, schedules, marks and released results.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_rds_cluster" "main" {
  count                               = var.enable_rds ? 1 : 0
  cluster_identifier                  = "${local.name}-aurora"
  engine                              = "aurora-postgresql"
  engine_version                      = "16.4"
  database_name                       = "exams"
  master_username                     = jsondecode(aws_secretsmanager_secret_version.db.secret_string).username
  master_password                     = random_password.db.result
  db_subnet_group_name                = aws_db_subnet_group.main.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  availability_zones                  = var.azs
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.data.arn
  enable_http_endpoint                = true # RDS Data API: no connection storms from 3,000 Lambdas
  backup_retention_period             = 35   # continuous backup -> point-in-time restore to the second
  preferred_backup_window             = "17:00-18:00"
  copy_tags_to_snapshot               = true
  deletion_protection                 = !var.use_floci
  skip_final_snapshot                 = var.use_floci
  final_snapshot_identifier           = var.use_floci ? null : "${local.name}-aurora-final"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  lifecycle {
    # Floci does not echo back engine, engine_mode or encryption settings; ignoring them
    # avoids a perpetual replace there and has no effect on AWS (they are fixed at creation).
    ignore_changes = [availability_zones, engine, engine_mode, kms_key_id, storage_encrypted]
  }
}

resource "aws_rds_cluster_instance" "main" {
  count                        = var.enable_rds ? 2 : 0
  identifier                   = "${local.name}-aurora-${substr(var.azs[count.index], -1, 1)}"
  cluster_identifier           = aws_rds_cluster.main[0].id
  instance_class               = var.db_instance_class
  engine                       = "aurora-postgresql"
  availability_zone            = var.azs[count.index] # instance 0 = writer (AZ-a), instance 1 = reader/failover target (AZ-b)
  promotion_tier               = count.index
  performance_insights_enabled = !var.use_floci
  publicly_accessible          = false

  lifecycle {
    # Floci places every instance in the first AZ and reports engine "postgres".
    ignore_changes = [engine, availability_zone]
  }
}

# ---------------------------------------------------------------------------
# DynamoDB: high-write autosave store and submission register
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "attempts" {
  name         = "${local.name}-attempts"
  billing_mode = "PAY_PER_REQUEST" # absorbs 3,000 students x 1 write / 30 s = ~100 WCU burst without capacity planning
  hash_key     = "attemptId"
  range_key    = "questionId"

  attribute {
    name = "attemptId"
    type = "S"
  }

  attribute {
    name = "questionId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true # RPO of seconds for answers
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }

  deletion_protection_enabled = !var.use_floci
}

resource "aws_dynamodb_table" "submissions" {
  name         = "${local.name}-submissions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "submissionId"

  attribute {
    name = "submissionId"
    type = "S"
  }

  attribute {
    name = "courseId"
    type = "S"
  }

  global_secondary_index {
    name            = "byCourse"
    hash_key        = "courseId"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }

  deletion_protection_enabled = !var.use_floci
}

# ---------------------------------------------------------------------------
# AWS Backup: daily + monthly copies retained 5 years (records requirement)
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "main" {
  count       = var.use_floci ? 0 : 1
  name        = "${local.name}-vault"
  kms_key_arn = aws_kms_key.data.arn
}

resource "aws_backup_plan" "main" {
  count = var.use_floci ? 0 : 1
  name  = "${local.name}-plan"

  rule {
    rule_name         = "daily-35d"
    target_vault_name = aws_backup_vault.main[0].name
    schedule          = "cron(0 18 * * ? *)"
    lifecycle {
      delete_after = 35
    }
  }

  rule {
    rule_name         = "monthly-5y"
    target_vault_name = aws_backup_vault.main[0].name
    schedule          = "cron(0 19 1 * ? *)"
    lifecycle {
      cold_storage_after = 90
      delete_after       = 365 * var.retention_years
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.use_floci ? 0 : 1
  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.use_floci ? 0 : 1
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "main" {
  count        = var.use_floci ? 0 : 1
  name         = "${local.name}-selection"
  plan_id      = aws_backup_plan.main[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources = compact([
    try(aws_rds_cluster.main[0].arn, ""),
    aws_dynamodb_table.attempts.arn,
    aws_dynamodb_table.submissions.arn,
  ])
}
