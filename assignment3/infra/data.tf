# ---------------------------------------------------------------------------
# Relational system of record: Aurora PostgreSQL Serverless v2 (change C1)
# writer in AZ-a, reader / failover target in AZ-b. Users, courses, exam definitions,
# schedules, marks and released results. Capacity follows load between 0.5 and 16 ACU
# instead of two always-on db.r6g.large instances.
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

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu # raised to 4 by exam-window.sh before an exam
    max_capacity = var.aurora_max_acu
  }

  lifecycle {
    # Floci does not echo back engine, engine_mode or encryption settings; ignoring them
    # avoids a perpetual replace there and has no effect on AWS (they are fixed at creation).
    ignore_changes = [availability_zones, engine, engine_mode, kms_key_id, storage_encrypted]
  }
}

resource "aws_rds_cluster_instance" "main" {
  count              = var.enable_rds ? 2 : 0
  identifier         = "${local.name}-aurora-${substr(var.azs[count.index], -1, 1)}"
  cluster_identifier = aws_rds_cluster.main[0].id
  instance_class     = "db.serverless"
  engine             = "aurora-postgresql"
  availability_zone  = var.azs[count.index] # instance 0 = writer (AZ-a), instance 1 = reader/failover target (AZ-b)
  # Tier 2 lets the reader scale on its own load (it serves almost nothing) instead of
  # mirroring the writer's ACUs. On failover it is promoted and scales up within seconds.
  promotion_tier               = count.index == 0 ? 0 : 2
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

# Change C9: Assignment 2 ran one plan (daily x35 + monthly x60) over Aurora AND DynamoDB.
# A DynamoDB backup is a full copy, so 35 dailies of a 10 GB table cost ~USD 40/month while
# PITR already gives any second of the last 35 days. DynamoDB now only gets the monthly 5-year copy.
resource "aws_backup_plan" "daily" {
  count = var.use_floci ? 0 : 1
  name  = "${local.name}-daily-aurora"

  rule {
    rule_name         = "daily-35d"
    target_vault_name = aws_backup_vault.main[0].name
    schedule          = "cron(0 18 * * ? *)"
    lifecycle {
      delete_after = 35
    }
  }
}

resource "aws_backup_plan" "monthly" {
  count = var.use_floci ? 0 : 1
  name  = "${local.name}-monthly-5y"

  rule {
    rule_name         = "monthly-5y"
    target_vault_name = aws_backup_vault.main[0].name
    schedule          = "cron(0 19 1 * ? *)"
    lifecycle {
      # DynamoDB backups move to cold storage (USD 0.0342 vs 0.114 per GB-month). Aurora
      # snapshots do not support cold storage, so AWS Backup keeps them warm.
      cold_storage_after                        = 90
      delete_after                              = 365 * var.retention_years
      opt_in_to_archive_for_supported_resources = true
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

resource "aws_backup_selection" "daily" {
  count        = var.use_floci ? 0 : 1
  name         = "${local.name}-daily-aurora"
  plan_id      = aws_backup_plan.daily[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = compact([try(aws_rds_cluster.main[0].arn, "")])
}

resource "aws_backup_selection" "monthly" {
  count        = var.use_floci ? 0 : 1
  name         = "${local.name}-monthly-5y"
  plan_id      = aws_backup_plan.monthly[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources = compact([
    try(aws_rds_cluster.main[0].arn, ""),
    aws_dynamodb_table.attempts.arn,
    aws_dynamodb_table.submissions.arn,
  ])
}
