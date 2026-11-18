#!/usr/bin/env bash
# F2 - Marking worker outage right after an exam closes (e.g. a bad marker release, or the
# function throttled to 0 while it is investigated).
# Expected impact: students still get "202 submitted" (the API only enqueues); attempts wait
# in the SQS marking queue (4-day retention, DLQ after 5 failures). No submission is lost
# (RPO 0); results are late until the worker is fixed (RTO = fix time + drain time).
source "$(dirname "$0")/lib.sh"
Q="$(tf output -json queues | python3 -c 'import json,sys;print(json.load(sys.stdin)["marking"])')"
FN=exams-sg-marker
depth() { aws sqs get-queue-attributes --queue-url "$Q" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text | awk '{print "marking queue: visible="$1" in-flight="$2}'; }
marked() { aws rds-data execute-statement --resource-arn "$DB" --secret-arn "$SECRET" --database exams \
  --sql "SELECT count(*) FROM results r JOIN attempts a USING (attempt_id) WHERE a.student_id BETWEEN 'lt-2801' AND 'lt-2810'" \
  --query 'records[0][0].longValue' --output text; }

step "1. FAILURE at $(ts): marker Lambda stopped (reserved concurrency 0)"
T_FAIL=$(now)
aws lambda put-function-concurrency --function-name "$FN" --reserved-concurrent-executions 0 --query ReservedConcurrentExecutions --output text | sed 's/^/marker reserved concurrency: /'

step "2. 10 students submit while marking is down"
for i in $(seq 2801 2810); do
  U="lt-$i"; H=(-H "x-demo-user: $U" -H "x-demo-groups: students" -H "content-type: application/json")
  A="$(curl -s -X POST "${H[@]}" "$API/exams/dso303-midterm/attempts" | python3 -c 'import json,sys;print(json.load(sys.stdin)["attemptId"])')"
  curl -s -X PUT "${H[@]}" "$API/attempts/$A/answers" -d "{\"clientTs\":$(date +%s%3N),\"answers\":[{\"questionId\":\"q1\",\"value\":\"RDS/Aurora Multi-AZ\"},{\"questionId\":\"q2\",\"value\":\"SQS\"}]}" >/dev/null
  printf '%s %s submit -> %s\n' "$(ts)" "$U" "$(curl -s -X POST "${H[@]}" "$API/attempts/$A/submit")"
done
sleep 10; depth; echo "results rows for these students: $(marked)/10"

step "3. FIX at $(ts): restore the worker from code (terraform apply sets reserved concurrency 50)"
T_FIX=$(now)
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" -no-color 2>&1 | grep -E 'Apply complete'
aws lambda get-function-concurrency --function-name "$FN" --query ReservedConcurrentExecutions --output text | sed 's/^/marker reserved concurrency: /'

step "4. Backlog drains"
for i in $(seq 1 40); do
  M="$(marked)"; echo "$(ts)  marked $M/10   $(depth)"
  [[ "$M" == "10" ]] && break; sleep 6
done
echo "RPO: $((10 - M)) submissions lost. Drain after fix: $(( $(now) - T_FIX ))s. Incident length: $(( $(now) - T_FAIL ))s (RTO target 3600s)"
