#!/usr/bin/env bash
# F4 - A broken api release goes out in the middle of an exam.
# Expected impact: every API call returns 5xx, so autosaves fail. The SPA keeps unsent answers
# in localStorage and re-sends them, so nothing is lost if the release is rolled back fast.
# Fix: roll back. In AWS the "live" alias is pointed back at the previous published version
# (seconds); Floci has no aliases, so the last good build (infra/.build/api.zip, built by
# terraform from the repository) is redeployed. Prevention: CI smoke test + no
# deploys during exam windows.
source "$(dirname "$0")/lib.sh"
FN=exams-sg-api
start_traffic 100 2620
sleep 12

step "1. FAILURE at $(ts): broken release of $FN deployed"
T_FAIL=$(now)
mkdir -p /tmp/f4 && printf 'export const handler = async () => { throw new Error("release 2026.11.15-bad: TypeError in autosave"); };\n' > /tmp/f4/index.mjs
(cd /tmp/f4 && rm -f bad.zip && zip -q bad.zip index.mjs)
aws lambda update-function-code --function-name "$FN" --zip-file fileb:///tmp/f4/bad.zip --query '[FunctionName,LastUpdateStatus]' --output text | sed 's/^/deployed: /'
for i in 1 2; do
  printf '%s  PUT autosave -> ' "$(ts)"; curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 -X PUT -H 'x-demo-user: lt-2601' -H 'x-demo-groups: students' "$API/attempts/x/answers" -d '{}'
done
echo "alarm api-5xx would fire after 2 x 60 s; on-call rolls back"
sleep 15

step "2. ROLLBACK at $(ts): redeploy the last good build"
T_RB=$(now)
aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$INFRA/.build/api.zip" \
  --query '[FunctionName,LastUpdateStatus]' --output text | sed 's/^/rolled back: /'
printf '%s  GET /health -> ' "$(ts)"; curl -s --max-time 30 "$API/health"; echo
echo "rollback took $(( $(now) - T_RB ))s; outage $(( $(now) - T_FAIL ))s"

step "3. RPO: answers typed during the outage were re-sent from the browser copy"
verify_rpo
echo "RTO measured: $(( $(now) - T_FAIL ))s including the browser re-sync (target 3600s)"
