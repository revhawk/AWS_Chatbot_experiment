#!/usr/bin/env bash
# AWS Resource Group module

# Re-tag any reused resources with the current Stack/Stage tags so they are
# included in the newly created AWS Resource Group alongside newly built parts.
retag_reused_resources() {
  local has_reused="false"
  if [ "${KB_REUSED:-false}" = "true" ] || [ "${GUARDRAIL_MANAGED:-true}" = "false" ] || [ "${DDB_REUSED:-false}" = "true" ]; then
    has_reused="true"
  fi
  [ "${has_reused}" != "true" ] && return 0

  echo "=== 8a. Tagging reused resources into Stack=${SUFFIX} for Resource Group inclusion ==="

  if [ "${KB_REUSED:-false}" = "true" ] && [ -n "${KB_ID:-}" ]; then
    local kb_arn="arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:knowledge-base/${KB_ID}"
    aws bedrock-agent tag-resource --resource-arn "${kb_arn}" --tags "$(tags_kv)" --region "${AWS_REGION}" >/dev/null 2>&1 || true
    [ -n "${SOURCE_BUCKET:-}" ] && aws s3api put-bucket-tagging --bucket "${SOURCE_BUCKET}" --tagging "$(tags_s3)" --region "${AWS_REGION}" >/dev/null 2>&1 || true
    [ -n "${SUPP_BUCKET:-}" ] && aws s3api put-bucket-tagging --bucket "${SUPP_BUCKET}" --tagging "$(tags_s3)" --region "${AWS_REGION}" >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    [ -n "${KB_ROLE_NAME:-}" ] && aws iam tag-role --role-name "${KB_ROLE_NAME}" --tags $(tags_iam) >/dev/null 2>&1 || true
  fi

  if [ "${GUARDRAIL_MANAGED:-true}" = "false" ] && [ -n "${GUARDRAIL_ID:-}" ]; then
    local gr_arn="arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:guardrail/${GUARDRAIL_ID}"
    # shellcheck disable=SC2046
    aws bedrock tag-resource --resource-arn "${gr_arn}" --tags $(tags_bedrock_kv) --region "${AWS_REGION}" >/dev/null 2>&1 || true
  fi

  if [ "${DDB_REUSED:-false}" = "true" ] && [ -n "${DDB_TABLE:-}" ]; then
    local ddb_arn="arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_TABLE}"
    # shellcheck disable=SC2046
    aws dynamodb tag-resource --resource-arn "${ddb_arn}" --tags $(tags_iam) --region "${AWS_REGION}" >/dev/null 2>&1 || true
  fi
}

deploy_resource_group() {
  retag_reused_resources
  echo "=== 8. Creating AWS Resource Group (${RESOURCE_GROUP_NAME}) ==="
  cat > /tmp/resource-group-query.json <<EOT
{
  "Type": "TAG_FILTERS_1_0",
  "Query": "{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Project\",\"Values\":[\"${APP_NAME}\"]},{\"Key\":\"Stack\",\"Values\":[\"${SUFFIX}\"]}]}"
}
EOT

  aws resource-groups create-group \
    --name "${RESOURCE_GROUP_NAME}" \
    --description "AWS Bedrock RAG Chatbot ${FULL_PREFIX} ${STAGE} ${SUFFIX}" \
    --resource-query file:///tmp/resource-group-query.json \
    --tags "$(tags_kv)" \
    --region "${AWS_REGION}" >/dev/null
}

teardown_resource_group() {
  if [ -n "${RESOURCE_GROUP_NAME:-}" ]; then
    echo "Deleting Resource Group (${RESOURCE_GROUP_NAME})..."
    aws resource-groups delete-group --group-name "${RESOURCE_GROUP_NAME}" --region "${AWS_REGION}" >/dev/null || true
  fi
}
