#!/usr/bin/env bash
# Walkthrough 1: a student signs in, opens an exam and their answers autosave.
source "$(dirname "$0")/common.sh"
API="$(out api_url)"; POOL="$(out cognito_user_pool_id)"; CLIENT="$(out cognito_client_id)"
TABLE="$(out attempts_table)"; DB="$(out db_cluster_arn)"; SECRET="$(out db_secret_arn)"
STU="${STU:-0001}"   # STU=0002 uses the second seeded student
STUDENT="student$STU@students.example-university.edu"
# Floci has no JWT authorizer, so the identity the authorizer would extract is passed as headers.
H=(-H "x-demo-user: stu-$STU" -H "x-demo-groups: students" -H "content-type: application/json")

step "1. Cognito sign-in (student is in the 'students' group)"
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$STUDENT" \
  --temporary-password 'TempPassw0rd!' --message-action SUPPRESS >/dev/null 2>&1 || true
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$STUDENT" --password 'Exam-Day-2026' --permanent
aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$STUDENT" --group-name students
TOKEN="$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$STUDENT",PASSWORD='Exam-Day-2026' --query AuthenticationResult.IdToken --output text)"
echo "IdToken: ${TOKEN:0:40}...  (groups: $(aws cognito-idp admin-list-groups-for-user --user-pool-id "$POOL" --username "$STUDENT" --query 'Groups[].GroupName' --output text))"

step "2. GET /exams/dso303-midterm  (API Gateway -> api Lambda -> Aurora via Data API)"
curl -sS "${H[@]}" "$API/exams/dso303-midterm" | python3 -m json.tool | head -30

step "3. POST /exams/dso303-midterm/attempts  (start the timer)"
ATTEMPT_JSON="$(curl -sS -X POST "${H[@]}" "$API/exams/dso303-midterm/attempts")"; echo "$ATTEMPT_JSON"
ATTEMPT="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["attemptId"])' "$ATTEMPT_JSON")"

step "4. Autosave every 30 s: PUT /attempts/$ATTEMPT/answers  (-> DynamoDB, conditional write)"
T0=$(( $(date +%s) * 1000 ))
curl -sS -X PUT "${H[@]}" "$API/attempts/$ATTEMPT/answers" \
  -d "{\"clientTs\":$T0,\"answers\":[{\"questionId\":\"q1\",\"value\":\"RDS/Aurora Multi-AZ\"},{\"questionId\":\"q2\",\"value\":\"Route 53\"}]}"; echo "   <- t=0s"
curl -sS -X PUT "${H[@]}" "$API/attempts/$ATTEMPT/answers" \
  -d "{\"clientTs\":$((T0+30000)),\"answers\":[{\"questionId\":\"q2\",\"value\":\"SQS\"},{\"questionId\":\"q3\",\"value\":\"S3 presigned URL\"},{\"questionId\":\"q4\",\"value\":\"RPO = data you can lose; RTO = time to restore.\"}]}"; echo "   <- t=30s"
echo "Late retry of the t=0s request (must NOT overwrite the newer q2 answer):"
curl -sS -X PUT "${H[@]}" "$API/attempts/$ATTEMPT/answers" \
  -d "{\"clientTs\":$T0,\"answers\":[{\"questionId\":\"q2\",\"value\":\"Route 53\"}]}"; echo

step "5. Answers stored in DynamoDB table $TABLE"
aws dynamodb query --table-name "$TABLE" --key-condition-expression 'attemptId = :a' \
  --expression-attribute-values "{\":a\":{\"S\":\"$ATTEMPT\"}}" \
  --query 'Items[].[questionId.S, value.S || status.S, savedAt.S || endsAt.S]' --output table

step "6. Submit -> SQS marking queue -> marker Lambda auto-marks MCQs"
curl -sS -X POST "${H[@]}" "$API/attempts/$ATTEMPT/submit"; echo
for i in $(seq 1 20); do
  R="$(aws rds-data execute-statement --resource-arn "$DB" --secret-arn "$SECRET" --database exams \
     --sql "SELECT attempt_id, mcq_score, mcq_total, status FROM results WHERE attempt_id = '$ATTEMPT'" \
     --query 'records[0]' --output text 2>/dev/null)"
  [[ -n "$R" && "$R" != "None" ]] && break; sleep 3
done
aws rds-data execute-statement --resource-arn "$DB" --secret-arn "$SECRET" --database exams \
  --sql "SELECT r.attempt_id, a.student_id, r.mcq_score, r.mcq_total, r.status FROM results r JOIN attempts a USING (attempt_id) WHERE attempt_id = '$ATTEMPT'" \
  | python3 -c 'import json,sys; r=[list(f.values())[0] for f in json.load(sys.stdin)["records"][0]]; print(f"Aurora results row: attempt={r[0]} student={r[1]} mcq_score={r[2]}/{r[3]} status={r[4]}")'
echo "marker log:"; aws logs filter-log-events --log-group-name "/aws/lambda/$(tf output -json lambda_functions | python3 -c 'import json,sys;print(json.load(sys.stdin)["marker"])')" \
  --filter-pattern "$ATTEMPT" --query 'events[-1].message' --output text 2>/dev/null | grep -o '{.*}' | tail -1
