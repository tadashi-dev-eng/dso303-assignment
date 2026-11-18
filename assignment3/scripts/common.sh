# shellcheck shell=bash
# Shared settings. ENV=floci (default) targets the local Floci emulator; ENV=prod targets AWS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
ENV="${ENV:-floci}"
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
if [[ "$ENV" == "floci" ]]; then
  export AWS_ENDPOINT_URL="${FLOCI_ENDPOINT:-http://localhost:4566}"
  export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
fi
tf() { terraform -chdir="$INFRA" "$@"; }
out() { tf output -raw "$1"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
