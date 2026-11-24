#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/guardrail.sh"
source "${SCRIPT_DIR}/scripts/storage.sh"
source "${SCRIPT_DIR}/scripts/knowledge_base.sh"
source "${SCRIPT_DIR}/scripts/compute_api.sh"
source "${SCRIPT_DIR}/scripts/resource_group.sh"
source "${SCRIPT_DIR}/scripts/checks.sh"

# Parse optional flags: ./deploy.sh [--config <file>] [--yes|-y] [--skip-smoke-test] [stage] [memory_mode] [app_name] [prefix]
CONFIG_FILE="${SCRIPT_DIR}/config.env"
AUTO_APPROVE="false"
SKIP_SMOKE_TEST_FLAG="false"
POSITIONAL_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --yes|-y)
      AUTO_APPROVE="true"
      shift
      ;;
    --skip-smoke-test)
      SKIP_SMOKE_TEST_FLAG="true"
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

if [ -f "${CONFIG_FILE}" ]; then
  echo "Loading configuration from ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi
[ "${SKIP_SMOKE_TEST_FLAG}" = "true" ] && RUN_SMOKE_TEST="false"

# CLI positional overrides (optional): ./deploy.sh [stage] [memory_mode] [app_name] [prefix]
[ -n "${1:-}" ] && STAGE="$1"
[ -n "${2:-}" ] && MEMORY_MODE="$2"
[ -n "${3:-}" ] && APP_NAME="$3"
[ -n "${4:-}" ] && PREFIX="$4"

prompt_var STAGE "Enter API Gateway stage to deploy to (e.g. dev, staging, prod)" "prod"
if [[ ! "${STAGE}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: Stage name '${STAGE}' must contain only letters, numbers, hyphens, or underscores."
  exit 1
fi

if [ -z "${MEMORY_MODE:-}" ]; then
  echo ""
  echo "Conversation memory mode:"
  echo "  single - Each question is answered independently (no prior chat history sent; lower token cost)."
  echo "  multi  - Loads recent session turns from DynamoDB so you can ask follow-up questions."
fi
prompt_var MEMORY_MODE "Choose memory mode (single/multi)" "single"
MEMORY_MODE=$(echo "${MEMORY_MODE}" | tr '[:upper:]' '[:lower:]')
if [[ "${MEMORY_MODE}" != "single" && "${MEMORY_MODE}" != "multi" ]]; then
  echo "Error: Memory mode '${MEMORY_MODE}' must be 'single' or 'multi'."
  exit 1
fi

prompt_var APP_NAME "Enter a main project name for all resources (lowercase, hyphens ok)" "bedrock-rag"
APP_NAME=$(echo "${APP_NAME}" | sed 's/^-*//;s/-*$//' | tr -s '-')
validate_slug "${APP_NAME}" "Project name"

prompt_var PREFIX "Enter a prefix for all resources (lowercase, hyphens ok)" "lab"
PREFIX=$(echo "${PREFIX}" | sed 's/^-*//;s/-*$//' | tr -s '-')
validate_slug "${PREFIX}" "Prefix"

prompt_var TAG_COST_CENTRE "Enter tag value for 'CostCentre'" "IT"
prompt_var TAG_RESOURCE_ID "Enter tag value for 'ResourceID'" "001"

export AWS_REGION="${AWS_REGION:-eu-west-1}"
KB_MODE=$(echo "${KB_MODE:-vector}" | tr '[:upper:]' '[:lower:]')
if [[ "${KB_MODE}" != "vector" && "${KB_MODE}" != "managed" ]]; then
  echo "Error: KB_MODE '${KB_MODE}' must be 'vector' or 'managed'."
  exit 1
fi
SHAREPOINT_PERMISSION_SCOPE="${SHAREPOINT_PERMISSION_SCOPE:-Sites.Selected}"
if [[ "${SHAREPOINT_PERMISSION_SCOPE}" != "Sites.Selected" && "${SHAREPOINT_PERMISSION_SCOPE}" != "Sites.Read.All" ]]; then
  echo "Error: SHAREPOINT_PERMISSION_SCOPE '${SHAREPOINT_PERMISSION_SCOPE}' must be 'Sites.Selected' or 'Sites.Read.All'."
  exit 1
fi
FULL_PREFIX="${PREFIX}-${APP_NAME}"

require_cmd aws
require_cmd zip

if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "Error: AWS CLI is not authenticated. Run 'aws login --remote' (Podman) or 'aws sso login' first."
  exit 1
fi

SUFFIX=$(date +%s)
resolve_existing_guardrail
resolve_existing_knowledge_base
resolve_existing_ddb_table
RESOURCE_GROUP_NAME="${FULL_PREFIX}-${STAGE}-${SUFFIX}"
if [ "${KB_REUSED}" != "true" ]; then
  SOURCE_BUCKET="${FULL_PREFIX}-docs-${ACCOUNT_ID}-${SUFFIX}"
  SUPP_BUCKET="${FULL_PREFIX}-bda-supp-${ACCOUNT_ID}-${SUFFIX}"
  VECTOR_BUCKET="${FULL_PREFIX}-vec-${SUFFIX}"
  VECTOR_INDEX="whitepapers-index"
  KB_NAME="${FULL_PREFIX}-kb-${SUFFIX}"
  KB_ROLE_NAME="${FULL_PREFIX}-kb-role-${SUFFIX}"
fi
if [ "${DDB_REUSED}" != "true" ]; then
  DDB_TABLE="${FULL_PREFIX}-history-${SUFFIX}"
fi
LAMBDA_ROLE_NAME="${FULL_PREFIX}-lambda-role-${SUFFIX}"
LAMBDA_NAME="${FULL_PREFIX}-chat-${SUFFIX}"
API_NAME="${FULL_PREFIX}-api-${SUFFIX}"

pre_deploy_check
init_run_log "deploy" "${FULL_PREFIX}"

echo "Deploying ${FULL_PREFIX} (stage=${STAGE}, kb_mode=${KB_MODE}, memory=${MEMORY_MODE}, region=${AWS_REGION})"
echo "Tags: Project=${APP_NAME}, Stage=${STAGE}, CostCentre=${TAG_COST_CENTRE}, ResourceID=${TAG_RESOURCE_ID}"

deploy_guardrail
deploy_storage
deploy_knowledge_base
deploy_compute_api
deploy_resource_group

cat > .env.lab <<EOT
CONFIG_FILE=${CONFIG_FILE}
AWS_REGION=${AWS_REGION}
APP_NAME=${APP_NAME}
PREFIX=${PREFIX}
TAG_COST_CENTRE=${TAG_COST_CENTRE}
TAG_RESOURCE_ID=${TAG_RESOURCE_ID}
STAGE=${STAGE}
KB_MODE=${KB_MODE}
MEMORY_MODE=${MEMORY_MODE}
SHAREPOINT_PERMISSION_SCOPE=${SHAREPOINT_PERMISSION_SCOPE}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME}
SOURCE_BUCKET=${SOURCE_BUCKET:-}
SUPP_BUCKET=${SUPP_BUCKET:-}
VECTOR_BUCKET=${VECTOR_BUCKET:-}
VECTOR_INDEX=${VECTOR_INDEX:-}
KB_NAME=${KB_NAME:-}
KB_ID=${KB_ID}
KB_MANAGED=${KB_MANAGED}
GUARDRAIL_ID=${GUARDRAIL_ID}
GUARDRAIL_MANAGED=${GUARDRAIL_MANAGED}
KB_ROLE_NAME=${KB_ROLE_NAME:-}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME}
LAMBDA_NAME=${LAMBDA_NAME}
DDB_TABLE=${DDB_TABLE}
API_ID=${API_ID}
API_KEY_ID=${API_KEY_ID}
PLAN_ID=${PLAN_ID}
EOT

post_deploy_smoke_test

echo ""
echo "Deployment complete! Run these commands in your host terminal to start chatting:"
echo "cd \"${SCRIPT_DIR}\""
echo "export RAG_API_URL=\"${API_URL}\""
echo "export RAG_API_KEY=\"${API_KEY_VAL}\""
echo "python3 chat_cli.py"
