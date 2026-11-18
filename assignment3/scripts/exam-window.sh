#!/usr/bin/env bash
# Exam window (change C4, sized by the load test):
#   ./scripts/exam-window.sh open [pc] [min_acu]   30 min before an exam starts (default 50 warm API instances, Aurora min 4 ACU)
#   ./scripts/exam-window.sh close                 ~1 h after the start, once the 5-minute start surge is over
# Assignment 2 kept 300 provisioned instances for whole exam days. The exam peak is ~110 req/s
# (100 autosaves + 10 opens); at ~60-130 ms per request that is ~7-15 concurrent executions
# (Little's law), so 50 warm instances for the first hour of each exam is >3x headroom at ~2% of the cost.
source "$(dirname "$0")/common.sh"
case "${1:-}" in
  open)  PC="${2:-50}"; ACU="${3:-4}" ;;
  close) PC=0; ACU=0.5 ;;
  *) echo "usage: $0 open [instances] [min_acu] | close"; exit 1 ;;
esac
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" \
  -var "lambda_provisioned_concurrency=$PC" -var "aurora_min_acu=$ACU"
