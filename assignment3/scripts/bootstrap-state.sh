#!/usr/bin/env bash
# Creates the S3 state bucket and DynamoDB lock table (run once per environment).
source "$(dirname "$0")/common.sh"
BUCKET="exams-tfstate-$ENV"; TABLE="exams-tflock-$ENV"
# The state backend lives in the Region named in envs/<env>.backend.hcl.
export AWS_REGION="$(sed -n 's/^region *= *"\(.*\)"/\1/p' "$INFRA/envs/$ENV.backend.hcl")"
step "State bucket s3://$BUCKET"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
step "Lock table $TABLE"
aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1 || aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null
echo "state backend ready: bucket=$BUCKET table=$TABLE"
