#!/usr/bin/env bash
# Lists the deployed Assignment 3 resources in ap-southeast-1 (works against Floci or AWS).
source "$(dirname "$0")/common.sh"
P="$(tf output -json lambda_functions | python3 -c 'import json,sys;print(json.load(sys.stdin)["api"][:-4])')"
step "Region: $AWS_REGION   name prefix: $P"
step "Lambda functions (no VPC attachment -> no NAT gateway, no ENIs)"
aws lambda list-functions --query "Functions[?starts_with(FunctionName,'$P')].[FunctionName,Runtime,Architectures[0],MemorySize,Timeout,length(VpcConfig.SubnetIds || \`[]\`)]" --output table
echo "NAT gateways in the VPC: $(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$(out vpc_id)" --query 'length(NatGateways[?State==`available`])' --output text)"
aws ec2 describe-subnets --filters Name=vpc-id,Values="$(out vpc_id)" --query 'Subnets[].[AvailabilityZone,CidrBlock,Tags[?Key==`Tier`]|[0].Value]' --output text | sort | sed 's/^/subnet  /'
step "Aurora PostgreSQL Serverless v2"
aws rds describe-db-clusters --db-cluster-identifier "$P-aurora" --query 'DBClusters[0].[DBClusterIdentifier,Status,Port]' --output text | awk '{print "cluster "$1"  "$2"  port "$3}'
echo "configured (infra/data.tf): PITR 35 days, Data API on, Serverless v2 $(grep -E '^aurora_min_acu' infra/envs/prod.tfvars | awk '{print $3}')-16 ACU, reader promotion tier 2"
aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$P')].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]" --output text | sort | sed 's/^/instance  /'
step "DynamoDB tables (on-demand, PITR)"
for t in attempts submissions; do
  printf '%-22s PITR=%s\n' "$P-$t" "$(aws dynamodb describe-continuous-backups --table-name "$P-$t" --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text)"
done
step "S3 buckets, SQS queues"
aws s3api list-buckets --query "Buckets[?starts_with(Name,'$P')].Name" --output text | tr '\t' '\n'
aws sqs list-queues --queue-name-prefix "$P" --query 'QueueUrls' --output text | tr '\t' '\n' | sed 's#.*/##' | paste -sd' '
step "Edge: WAF (us-east-1, CLOUDFRONT scope) rate rules"
ACL="$(aws wafv2 list-web-acls --region us-east-1 --scope CLOUDFRONT --query "WebACLs[?starts_with(Name,'$P')]|[0].[Name,Id]" --output text)"
aws wafv2 get-web-acl --region us-east-1 --scope CLOUDFRONT --name "$(cut -f1 <<<"$ACL")" --id "$(cut -f2 <<<"$ACL")" \
  --query 'WebACL.Rules[].[Priority,Name,Statement.RateBasedStatement.Limit || `-`]' --output text | sort -n | sed 's/^/rule  /'
step "Alarms"
aws cloudwatch describe-alarms --alarm-name-prefix "$P" --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | paste -sd' '
aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix "$P" --query 'MetricAlarms[].AlarmName' --output text | sed 's/^/us-east-1: /'
