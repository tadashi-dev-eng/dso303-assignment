# shellcheck shell=bash
# Shared helpers for the failure tests (sourced). Uses the project's common.sh settings.
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
API="$(out api_url)"; DB="$(out db_cluster_arn)"; SECRET="$(out db_secret_arn)"
TABLE="$(out attempts_table)"; CLUSTER="${DB##*:}"
FT="$ROOT/infra/failure-tests"
now() { date +%s; }
ts() { date -u +%H:%M:%SZ; }

# start_traffic <seconds> <offset> : background autosave traffic, output in /tmp/traffic-$$.json
start_traffic() {
  TRAFFIC_OUT="/tmp/traffic-$$.json"
  API="$API" node "$FT/exam-traffic.mjs" --students 5 --interval 3 --seconds "$1" --offset "$2" --out "$TRAFFIC_OUT" \
    > "/tmp/traffic-$$.log" 2>&1 &
  TRAFFIC_PID=$!
}

# RPO check: the newest answer each client produced must be the one stored in DynamoDB.
verify_rpo() {
  wait "$TRAFFIC_PID"
  tail -1 "/tmp/traffic-$$.log"
  python3 - "$TRAFFIC_OUT" "$TABLE" <<'PY'
import json, subprocess, sys
d = json.load(open(sys.argv[1])); lost = 0
for s in d["students"]:
    out = subprocess.run(["aws", "dynamodb", "get-item", "--table-name", sys.argv[2], "--output", "json",
        "--key", json.dumps({"attemptId": {"S": s["attemptId"]}, "questionId": {"S": "q4"}})], capture_output=True, text=True).stdout
    stored = json.loads(out)["Item"]["value"]["S"] if out.strip() else None
    ok = stored == s["last"]; lost += 0 if ok else 1
    print(f"  {s['user']}  client latest={s['last']:<14} stored={str(stored):<14} {'OK' if ok else 'LOST'}")
print(f"RPO measured: {lost} answers lost (target: at most 5 minutes of work)")
PY
}
