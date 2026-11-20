#!/usr/bin/env bash
# AWS Resource Group module

deploy_resource_group() {
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
