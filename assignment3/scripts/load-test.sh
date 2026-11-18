#!/usr/bin/env bash
# Exam-start load test with CloudWatch evidence.
#   ./scripts/load-test.sh before   Assignment 2 behaviour: exam cache off, no pre-warm
#   ./scripts/load-test.sh after    fixes B1 + C4: exam cache 60 s, execution environments pre-warmed
# Scale: Floci on a laptop cannot serve 3,000 students, so the same shape runs scaled down:
# 40 students arrive over 60 s (0.67/s instead of 10/s), then autosave every 30 s.
source "$(dirname "$0")/common.sh"
RUN="${1:?usage: $0 before|after}"
STUDENTS="${STUDENTS:-40}"; RAMP="${RAMP:-60}"; HOLD="${HOLD:-90}"
case "$RUN" in
  before) CACHE=0;  PREWARM=0;  OFFSET="${OFFSET:-2000}" ;;
  after)  CACHE=60; PREWARM=10; OFFSET="${OFFSET:-2100}" ;;
  *) echo "usage: $0 before|after"; exit 1 ;;
esac
FN="$(tf output -json lambda_functions | python3 -c 'import json,sys;print(json.load(sys.stdin)["api"])')"
API="$(out api_url)"

# Load-test students lt-0001..lt-3000 (idempotent).
aws rds-data execute-statement --resource-arn "$(out db_cluster_arn)" --secret-arn "$(out db_secret_arn)" --database exams \
  --sql "INSERT INTO users (user_id,email,full_name,role) SELECT 'lt-'||lpad(g::text,4,'0'), 'lt'||g||'@students.example-university.edu', 'Load student '||g, 'student' FROM generate_series(1,3000) g ON CONFLICT DO NOTHING" >/dev/null

step "1. Configure: exam_cache_seconds=$CACHE (terraform apply resets every execution environment)"
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" -var "exam_cache_seconds=$CACHE" -no-color | grep -E 'Apply complete'

if (( PREWARM > 0 )); then
  step "2. Exam window: pre-warm $PREWARM execution environments"
  echo "AWS: ./scripts/exam-window.sh open 50 (provisioned concurrency). Floci has no provisioned concurrency,"
  echo "so the same effect is produced by $PREWARM concurrent warm-up requests (2 rounds)."
  T=$(date +%s)
  for round in 1 2; do   # through API Gateway, the same path students use
    seq 1 "$PREWARM" | xargs -P "$PREWARM" -I{} curl -s -o /dev/null --max-time 60 "$API/health" || true
  done
  echo "warm pool ready in $(( $(date +%s) - T ))s"
else
  step "2. No pre-warm (cold start at exam start, as in an unprepared exam)"
fi

streams() { aws logs describe-log-streams --log-group-name "/aws/lambda/$FN" --query 'logStreams[].logStreamName' --output text | tr '\t' '\n' | sort; }
streams > "/tmp/streams-$RUN.before"

step "3. Load: $STUDENTS students open the exam within ${RAMP}s, autosave every 30s, hold ${HOLD}s"
START_MS=$(( $(date +%s) * 1000 ))
API="$API" node "$ROOT/scripts/load-test.mjs" --students "$STUDENTS" --ramp "$RAMP" --autosave 30 --hold "$HOLD" \
  --run "$RUN" --offset "$OFFSET" --out "/tmp/load-$RUN.json"
END_MS=$(( $(date +%s) * 1000 + 60000 ))

step "4. CloudWatch metrics ExamPlatform/LoadTest (Run=$RUN), 60 s periods"
for M in Requests Errors5xx LatencyP95; do
  STAT=Sum; [[ $M == LatencyP95 ]] && STAT=Maximum
  aws cloudwatch get-metric-statistics --namespace ExamPlatform/LoadTest --metric-name "$M" \
    --dimensions Name=Run,Value="$RUN" --statistics "$STAT" --period 60 \
    --start-time "$(date -u -d @$((START_MS/1000 - 60)) +%FT%TZ)" --end-time "$(date -u -d @$((END_MS/1000)) +%FT%TZ)" \
    --query "sort_by(Datapoints,&Timestamp)[].$STAT" --output text | awk -v m="$M" -v s="$STAT" '{printf "%-11s %-7s per minute: ", m, s; for(i=1;i<=NF;i++) printf "%8.0f", $i; print ""}'
done

step "5. CloudWatch Logs /aws/lambda/$FN: cold starts and where request time goes"
# Every Lambda execution environment writes to its own log stream, so new streams = cold starts.
echo "new execution environments (cold starts) during the test: $(streams | comm -13 "/tmp/streams-$RUN.before" - | wc -l)"
aws logs filter-log-events --log-group-name "/aws/lambda/$FN" --start-time "$START_MS" --filter-pattern '"CloudWatchMetrics"' \
  --query 'events[].message' --output json | python3 -c '
import json, re, sys, collections
rows = collections.defaultdict(list)
for m in json.load(sys.stdin):
    j = re.search(r"\{.*\}", m)
    if j:
        e = json.loads(j.group(0)); rows[e["Route"]].append(e)
hdr = ("EMF route", "requests", "avg ms", "SQL calls/req", "SQL ms/req")
print(f"{hdr[0]:38} {hdr[1]:>8} {hdr[2]:>8} {hdr[3]:>14} {hdr[4]:>11}")
for r, es in sorted(rows.items()):
    n = len(es)
    dur = sum(e["DurationMs"] for e in es) / n; calls = sum(e["DbCalls"] for e in es) / n; dbms = sum(e["DbMs"] for e in es) / n
    print(f"{r:38} {n:8} {dur:8.0f} {calls:14.2f} {dbms:11.0f}")'
