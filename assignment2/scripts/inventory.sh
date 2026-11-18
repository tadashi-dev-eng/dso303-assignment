#!/usr/bin/env bash
# Lists the main deployed resources (works against Floci or AWS).
source "$(dirname "$0")/common.sh"
P="exams-$ENV"
step "Lambda functions"
aws lambda list-functions --query "Functions[?starts_with(FunctionName,'$P')].[FunctionName,Runtime,MemorySize,Timeout]" --output table
step "Aurora PostgreSQL cluster and instances"
aws rds describe-db-clusters --db-cluster-identifier "$P-aurora" --query 'DBClusters[0].[DBClusterIdentifier,Status,Endpoint,Port]' --output text
aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$P')].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]" --output text
step "DynamoDB tables (PITR)"
for t in attempts submissions; do
  printf '%-26s PITR=%s\n' "$P-$t" "$(aws dynamodb describe-continuous-backups --table-name "$P-$t" --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text)"
done
step "S3 buckets"
aws s3api list-buckets --query "Buckets[?starts_with(Name,'$P')].Name" --output text | tr '\t' '\n'
step "SQS queues"
aws sqs list-queues --queue-name-prefix "$P" --query 'QueueUrls' --output text | tr '\t' '\n' | sed 's#.*/##'
step "Cognito groups, WAF, Route 53, KMS, Secrets, alarms"
aws cognito-idp list-groups --user-pool-id "$(out cognito_user_pool_id)" --query 'Groups[].GroupName' --output text
aws wafv2 list-web-acls --scope CLOUDFRONT --query "WebACLs[?starts_with(Name,'$P')].Name" --output text
aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text
aws kms list-aliases --query "Aliases[?starts_with(AliasName,'alias/$P')].AliasName" --output text
aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'$P')].Name" --output text
aws cloudwatch describe-alarms --alarm-name-prefix "$P" --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n'
