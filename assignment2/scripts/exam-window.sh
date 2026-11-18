#!/usr/bin/env bash
# Pre-warm for an exam window: ./scripts/exam-window.sh open 300   |   ./scripts/exam-window.sh close
# Raises API Lambda provisioned concurrency through Terraform so the change is tracked in state.
source "$(dirname "$0")/common.sh"
case "${1:-}" in
  open)  PC="${2:-300}" ;;
  close) PC=0 ;;
  *) echo "usage: $0 open [instances] | close"; exit 1 ;;
esac
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars" -var "lambda_provisioned_concurrency=$PC"
