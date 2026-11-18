#!/usr/bin/env bash
# Full deployment: state backend -> terraform apply -> database migration -> smoke test.
source "$(dirname "$0")/common.sh"
"$ROOT/scripts/bootstrap-state.sh"
step "terraform init ($ENV)"
tf init -input=false -reconfigure -backend-config="envs/$ENV.backend.hcl"
step "terraform apply ($ENV)"
tf apply -input=false -auto-approve -var-file="envs/$ENV.tfvars"
step "Database migration (api Lambda, action=migrate)"
FN="$(tf output -json lambda_functions | python3 -c 'import json,sys;print(json.load(sys.stdin)["api"])')"
# Retry while the Aurora writer finishes booting.
TMP="$(mktemp)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
    --payload '{"action":"migrate"}' "$TMP" >/dev/null && grep -q migrated "$TMP" && break
  echo "  database not ready yet (attempt $i), retrying in 10s"; sleep 10
done
cat "$TMP"; echo; rm -f "$TMP"
step "Smoke test GET /health"
curl -fsS "$(out api_url)/health"; echo
