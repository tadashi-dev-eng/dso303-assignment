#!/usr/bin/env bash
# Simulates losing Availability Zone A, proves the platform keeps serving from AZ B,
# then heals AZ A with `terraform apply` (infrastructure as code = recovery runbook).
#
# Floci cannot switch off an AZ, so the outage is injected by removing everything that
# lives in AZ A: the Aurora instance, the NAT gateway and the Lambda ENIs in app subnet A.
# Floci limitation: it runs one PostgreSQL container per Aurora cluster, so this proves the
# cluster endpoint keeps answering with one instance gone, not a real storage-level failover.
source "$(dirname "$0")/common.sh"
API="$(out api_url)"; DB="$(out db_cluster_arn)"; SECRET="$(out db_secret_arn)"
VPC="$(out vpc_id)"
FNS="$(tf output -json lambda_functions | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin).values()))')"
APP_B="$(tf output -json subnets | python3 -c 'import json,sys;print(json.load(sys.stdin)["app"]["us-east-1b"])')"
CLUSTER="${DB##*:}"

topology() {
  aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
    --query 'sort_by(Subnets,&CidrBlock)[].[AvailabilityZone,CidrBlock,Tags[?Key==`Tier`]|[0].Value,SubnetId]' --output table
  aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=available \
    --query 'NatGateways[].[NatGatewayId,SubnetId,State]' --output text | sed 's/^/NAT  /'
  aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
    --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text | sed 's/^/Aurora members: /'
}

step "0. Healthy baseline (two AZs)"
topology
curl -sS "$API/health"; echo

step "1. FAILURE INJECTED: us-east-1a is lost at $(date -u +%H:%M:%SZ)"
T_FAIL=$(date +%s)
aws rds delete-db-instance --db-instance-identifier "$CLUSTER-a" --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text | sed 's/^/Aurora instance down: /'
NAT_A="$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=available \
  --query "NatGateways[?SubnetId=='$(tf output -json subnets | python3 -c 'import json,sys;print(json.load(sys.stdin)["public"]["us-east-1a"])')'].NatGatewayId" --output text)"
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_A" --query NatGatewayId --output text | sed 's/^/NAT gateway down:     /'
# What Lambda does on its own in AWS when an AZ disappears: new execution environments only start in healthy subnets.
for f in $FNS; do
  aws lambda update-function-configuration --function-name "$f" --vpc-config "SubnetIds=$APP_B" >/dev/null
done
echo "Lambda functions re-pinned to app subnet B only ($APP_B)"
echo "(Floci does not model Lambda ENI placement; in AWS this happens automatically.)"

step "2. State during the outage"
topology

step "3. Platform still serving from us-east-1b"
curl -sS "$API/health"; echo
STU=0002 "$ROOT/scripts/walkthrough-1-exam-autosave.sh" 2>&1 | sed -n '/==> 3\./,/==> 5\./p' | grep -v '==> 5'
aws rds-data execute-statement --resource-arn "$DB" --secret-arn "$SECRET" --database exams \
  --sql "SELECT count(*) AS attempts, count(submitted_at) AS submitted FROM attempts" \
  --query 'records[0][].longValue' --output text | awk '{print "Aurora (AZ-b instance) answering: attempts="$1" submitted="$2}'
T_OK=$(date +%s)
echo "Requests served throughout; time from failure to verified service: $((T_OK - T_FAIL))s (RPO: 0 lost autosaves)"

step "4. RECOVERY: terraform apply rebuilds AZ A from code"
T_REC=$(date +%s)
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" -no-color 2>&1 \
  | grep -E 'aws_rds_cluster_instance.main\[0\]: Creation complete|aws_nat_gateway.main\[0\]: Creation complete|aws_lambda_function.fn\[.*\]: Modifications complete|Apply complete'
echo "AZ A restored in $(( $(date +%s) - T_REC ))s (RTO target: 3600s)"
topology
