#!/usr/bin/env bash
# F1 - Loss of Availability Zone ap-southeast-1a during an exam.
# Expected impact: the Aurora writer in AZ-a disappears. Aurora promotes the AZ-b reader
# (~30 s in AWS); exam opens/submits fail during that window; autosaves (DynamoDB, regional)
# and the SPA (CloudFront) are unaffected; Lambda is not in the VPC, so there is no NAT/ENI to lose.
# Floci note: one PostgreSQL container serves the cluster, so the outage is injected by deleting
# the AZ-a instance; real failover timing comes from AWS (documented in README.md).
source "$(dirname "$0")/lib.sh"

step "0. Baseline: Aurora cluster members and Lambda networking"
aws rds describe-db-instances --query "DBInstances[?DBClusterIdentifier=='$CLUSTER'].[DBInstanceIdentifier,AvailabilityZone,DBInstanceStatus]" --output table
for f in api marker notifier; do
  echo "lambda exams-sg-$f VPC subnets: $(aws lambda get-function-configuration --function-name "exams-sg-$f" --query 'length(VpcConfig.SubnetIds || `[]`)' --output text) (runs in every AZ of the Region)"
done
start_traffic 75 2900
sleep 12

step "1. FAILURE at $(ts): ap-southeast-1a lost (Aurora writer instance removed)"
T_FAIL=$(now)
aws rds delete-db-instance --db-instance-identifier "$CLUSTER-a" --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text | sed 's/^/Aurora instance down: /'

step "2. During the outage: exam opens and Aurora reads"
for i in 1 2 3; do
  printf '%s  GET /exams/dso303-midterm -> ' "$(ts)"
  curl -s -o /dev/null -w '%{http_code} in %{time_total}s\n' --max-time 30 -H 'x-demo-user: lt-2950' -H 'x-demo-groups: students' "$API/exams/dso303-midterm"
done
aws rds-data execute-statement --resource-arn "$DB" --secret-arn "$SECRET" --database exams \
  --sql "SELECT count(*) FROM attempts" --query 'records[0][0].longValue' --output text | sed 's/^/Aurora (AZ-b member) answering, attempts rows: /'
T_SERVE=$(now)
echo "time from failure to verified service: $((T_SERVE - T_FAIL))s"

step "3. RPO: autosave traffic that ran through the failure"
verify_rpo

step "4. RECOVERY: terraform apply rebuilds the AZ-a instance from code"
T_REC=$(now)
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" -no-color 2>&1 | grep -E 'aws_rds_cluster_instance.main\[0\]: Creation complete|Apply complete'
aws rds describe-db-instances --query "DBInstances[?DBClusterIdentifier=='$CLUSTER'].[DBInstanceIdentifier,AvailabilityZone,DBInstanceStatus]" --output table
echo "AZ-a capacity restored in $(( $(now) - T_REC ))s; total incident $(( $(now) - T_FAIL ))s (RTO target 3600s)"
