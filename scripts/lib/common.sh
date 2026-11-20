#!/usr/bin/env bash
# Shared helpers for deploy.sh, teardown.sh, and scripts/*.sh

init_run_log() {
  local action="$1"
  local prefix="$2"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "${SCRIPT_DIR}/logs"
  LOG_FILE="${SCRIPT_DIR}/logs/${prefix}-${action}-${stamp}.log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  echo "Logging ${action} run to ${LOG_FILE}"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: '${cmd}' is required but not installed. See docs/RUNNING_SCRIPTS.md."
    exit 1
  fi
}

validate_slug() {
  local value="$1"
  local label="$2"
  if [[ ! "${value}" =~ ^[a-z0-9-]+$ ]]; then
    echo "Error: ${label} '${value}' must contain only lowercase letters, numbers, or hyphens."
    exit 1
  fi
}

# Prompt only if the variable is currently empty; otherwise keep its value from config.env/CLI.
prompt_var() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="$3"
  local current_val="${!var_name:-}"

  if [ -z "${current_val}" ]; then
    read -r -p "${prompt_text} [${default_val}]: " current_val
    current_val="${current_val:-$default_val}"
    printf -v "${var_name}" '%s' "${current_val}"
  fi
}

# --- Tag Formatters (single source of truth) ---
tags_kv() {
  echo "Project=${APP_NAME},Stage=${STAGE},Stack=${SUFFIX},CostCentre=${TAG_COST_CENTRE},ResourceID=${TAG_RESOURCE_ID}"
}

tags_bedrock_kv() {
  echo "key=Project,value=${APP_NAME} key=Stage,value=${STAGE} key=Stack,value=${SUFFIX} key=CostCentre,value=${TAG_COST_CENTRE} key=ResourceID,value=${TAG_RESOURCE_ID}"
}

tags_iam() {
  echo "Key=Project,Value=${APP_NAME} Key=Stage,Value=${STAGE} Key=Stack,Value=${SUFFIX} Key=CostCentre,Value=${TAG_COST_CENTRE} Key=ResourceID,Value=${TAG_RESOURCE_ID}"
}

tags_s3() {
  echo "TagSet=[{Key=Project,Value=${APP_NAME}},{Key=Stage,Value=${STAGE}},{Key=Stack,Value=${SUFFIX}},{Key=CostCentre,Value=${TAG_COST_CENTRE}},{Key=ResourceID,Value=${TAG_RESOURCE_ID}}]"
}

# --- IAM Helpers ---
create_role_with_inline_policy() {
  local role_name="$1"
  local trust_file="$2"
  local policy_name="$3"
  local policy_file="$4"
  local managed_arn="${5:-}"
  local role_arn

  # shellcheck disable=SC2046
  role_arn=$(aws iam create-role \
    --role-name "${role_name}" \
    --assume-role-policy-document "file://${trust_file}" \
    --tags $(tags_iam) \
    --query 'Role.Arn' --output text)

  if [ -n "${managed_arn}" ]; then
    aws iam attach-role-policy --role-name "${role_name}" --policy-arn "${managed_arn}"
  fi
  aws iam put-role-policy --role-name "${role_name}" --policy-name "${policy_name}" --policy-document "file://${policy_file}"
  echo "${role_arn}"
}

delete_iam_role() {
  local role_name="$1"
  [ -z "${role_name}" ] && return 0

  local p
  for p in $(aws iam list-attached-role-policies --role-name "${role_name}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${p}" || true
  done
  for p in $(aws iam list-role-policies --role-name "${role_name}" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    aws iam delete-role-policy --role-name "${role_name}" --policy-name "${p}" || true
  done
  aws iam delete-role --role-name "${role_name}" || true
}
