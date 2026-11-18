#!/usr/bin/env bash
# Tear-down. In prod, deletion protection on Aurora/DynamoDB must be switched off first
# (terraform apply -var deletion_protection=false is deliberately NOT automated).
source "$(dirname "$0")/common.sh"
step "terraform destroy ($ENV)"
tf init -input=false -reconfigure -backend-config="envs/$ENV.backend.hcl" >/dev/null
tf destroy -input=false -auto-approve -var-file="envs/$ENV.tfvars"
if [[ "${DELETE_STATE:-no}" == "yes" ]]; then
  step "Removing state bucket and lock table"
  aws s3 rb "s3://exams-tfstate-$ENV" --force
  aws dynamodb delete-table --table-name "exams-tflock-$ENV" >/dev/null
fi
