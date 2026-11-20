#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/guardrail.sh"
source "${SCRIPT_DIR}/scripts/storage.sh"
source "${SCRIPT_DIR}/scripts/knowledge_base.sh"
source "${SCRIPT_DIR}/scripts/compute_api.sh"
source "${SCRIPT_DIR}/scripts/resource_group.sh"

# Load non-interactive defaults from config.env if present (or pass --config <file>)
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [ "${1:-}" = "--config" ] && [ -n "${2:-}" ]; then
  CONFIG_FILE="$2"
  shift 2
fi
if [ -f "${CONFIG_FILE}" ]; then
  echo "Loading configuration from ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

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
validate_slug "${APP_NAME}" "Project name"

prompt_var PREFIX "Enter a prefix for all resources (lowercase, hyphens ok)" "lab"
validate_slug "${PREFIX}" "Prefix"

prompt_var TAG_COST_CENTRE "Enter tag value for 'CostCentre'" "IT"
prompt_var TAG_RESOURCE_ID "Enter tag value for 'ResourceID'" "001"

export AWS_REGION="${AWS_REGION:-eu-west-1}"
FULL_PREFIX="${PREFIX}-${APP_NAME}"

require_cmd aws
require_cmd zip

if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "Error: AWS CLI is not authenticated. Run 'aws login --remote' (Podman) or 'aws sso login' first."
  exit 1
fi

SUFFIX=$(date +%s)
RESOURCE_GROUP_NAME="${FULL_PREFIX}-${STAGE}-${SUFFIX}"
SOURCE_BUCKET="${FULL_PREFIX}-docs-${ACCOUNT_ID}-${SUFFIX}"
SUPP_BUCKET="${FULL_PREFIX}-bda-supp-${ACCOUNT_ID}-${SUFFIX}"
VECTOR_BUCKET="${FULL_PREFIX}-vec-${SUFFIX}"
VECTOR_INDEX="whitepapers-index"
KB_NAME="${FULL_PREFIX}-kb-${SUFFIX}"
KB_ROLE_NAME="${FULL_PREFIX}-kb-role-${SUFFIX}"
LAMBDA_ROLE_NAME="${FULL_PREFIX}-lambda-role-${SUFFIX}"
LAMBDA_NAME="${FULL_PREFIX}-chat-${SUFFIX}"
DDB_TABLE="${FULL_PREFIX}-history-${SUFFIX}"
API_NAME="${FULL_PREFIX}-api-${SUFFIX}"

echo "Deploying ${FULL_PREFIX} (stage=${STAGE}, memory=${MEMORY_MODE}, region=${AWS_REGION})"
echo "Tags: Project=${APP_NAME}, Stage=${STAGE}, CostCentre=${TAG_COST_CENTRE}, ResourceID=${TAG_RESOURCE_ID}"

deploy_guardrail
deploy_storage
deploy_knowledge_base
deploy_compute_api
deploy_resource_group

cat > .env.lab <<EOT
AWS_REGION=${AWS_REGION}
APP_NAME=${APP_NAME}
PREFIX=${PREFIX}
TAG_COST_CENTRE=${TAG_COST_CENTRE}
TAG_RESOURCE_ID=${TAG_RESOURCE_ID}
STAGE=${STAGE}
MEMORY_MODE=${MEMORY_MODE}
RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME}
SOURCE_BUCKET=${SOURCE_BUCKET}
SUPP_BUCKET=${SUPP_BUCKET}
VECTOR_BUCKET=${VECTOR_BUCKET}
VECTOR_INDEX=${VECTOR_INDEX}
KB_ID=${KB_ID}
GUARDRAIL_ID=${GUARDRAIL_ID}
GUARDRAIL_MANAGED=${GUARDRAIL_MANAGED}
KB_ROLE_NAME=${KB_ROLE_NAME}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME}
LAMBDA_NAME=${LAMBDA_NAME}
DDB_TABLE=${DDB_TABLE}
API_ID=${API_ID}
API_KEY_ID=${API_KEY_ID}
PLAN_ID=${PLAN_ID}
EOT

echo ""
echo "Deployment complete! Run these exports to test with chat_cli.py:"
echo "export RAG_API_URL=\"${API_URL}\""
echo "export RAG_API_KEY=\"${API_KEY_VAL}\""
