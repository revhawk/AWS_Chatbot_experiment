#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/guardrail.sh"
source "${SCRIPT_DIR}/scripts/storage.sh"
source "${SCRIPT_DIR}/scripts/knowledge_base.sh"
source "${SCRIPT_DIR}/scripts/compute_api.sh"
source "${SCRIPT_DIR}/scripts/resource_group.sh"

# Optional flags: ./teardown.sh [--config <file>] [--keep-kb | --delete-kb]
CONFIG_FILE_OVERRIDE=""
KEEP_KB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --keep-kb)
      KEEP_KB="true"
      shift
      ;;
    --delete-kb)
      KEEP_KB="false"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./teardown.sh [--config <file>] [--keep-kb | --delete-kb]"
      exit 1
      ;;
  esac
done

if [ ! -f .env.lab ]; then
  echo "Error: .env.lab not found. Nothing to tear down."
  exit 1
fi

# shellcheck disable=SC1091
source .env.lab
CONFIG_FILE="${CONFIG_FILE_OVERRIDE:-${CONFIG_FILE:-${SCRIPT_DIR}/config.env}}"

# Resolve KB_NAME if missing from older .env.lab files
if [ -n "${KB_ID:-}" ] && [ -z "${KB_NAME:-}" ]; then
  KB_NAME=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" \
    --query 'knowledgeBase.name' --output text 2>/dev/null || true)
  [ "${KB_NAME}" = "None" ] && KB_NAME=""
fi

if [ -n "${KB_ID:-}" ] && [ -z "${KEEP_KB}" ]; then
  echo ""
  echo "Bedrock Knowledge Base: ${KB_NAME:-<unnamed>} (${KB_ID})"
  echo "Keeping the Knowledge Base (and its S3/vector storage) avoids re-ingestion time and token costs on the next deploy."
  read -r -p "Type YES (in capital letters) to KEEP the Knowledge Base and save it to $(basename "${CONFIG_FILE}") (anything else deletes it): " KEEP_KB_REPLY
  if [ "${KEEP_KB_REPLY}" = "YES" ]; then
    KEEP_KB="true"
  else
    KEEP_KB="false"
  fi
fi

init_run_log "teardown" "${PREFIX:-lab}-${APP_NAME:-bedrock-rag}"
echo "=== Starting Teardown in ${AWS_REGION} ==="

teardown_compute_api
teardown_knowledge_base
teardown_storage
teardown_guardrail
teardown_resource_group

if [ "${KEEP_KB:-false}" = "true" ] && [ -n "${KB_ID:-}" ]; then
  [ -n "${KB_NAME:-}" ] && save_config_var "${CONFIG_FILE}" "KB_NAME" "${KB_NAME}"
  save_config_var "${CONFIG_FILE}" "KB_ID" "${KB_ID}"
  echo "Saved Knowledge Base (${KB_NAME:-$KB_ID} / ${KB_ID}) to ${CONFIG_FILE} for reuse on the next ./deploy.sh."
elif [ -n "${KB_ID:-}" ]; then
  clear_config_var "${CONFIG_FILE}" "KB_NAME"
  clear_config_var "${CONFIG_FILE}" "KB_ID"
fi

rm -f .env.lab
echo "=== Teardown Complete! ==="
