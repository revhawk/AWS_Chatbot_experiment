#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/guardrail.sh"
source "${SCRIPT_DIR}/scripts/storage.sh"
source "${SCRIPT_DIR}/scripts/knowledge_base.sh"
source "${SCRIPT_DIR}/scripts/compute_api.sh"
source "${SCRIPT_DIR}/scripts/resource_group.sh"

if [ ! -f .env.lab ]; then
  echo "Error: .env.lab not found. Nothing to tear down."
  exit 1
fi

# shellcheck disable=SC1091
source .env.lab
init_run_log "teardown" "${PREFIX:-lab}-${APP_NAME:-bedrock-rag}"
echo "=== Starting Teardown in ${AWS_REGION} ==="

teardown_compute_api
teardown_knowledge_base
teardown_storage
teardown_guardrail
teardown_resource_group

rm -f .env.lab
echo "=== Teardown Complete! ==="
