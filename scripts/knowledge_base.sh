#!/usr/bin/env bash
# Bedrock Knowledge Base + BDA Data Source + IAM Role module

# Populate backing resource names for an existing Knowledge Base so a later
# teardown can cleanly delete them if the user chooses not to keep the KB.
populate_reused_kb_metadata() {
  local kb_id="$1"
  local role_arn supp_uri vec_bucket_arn vec_index_arn ds_id src_bucket_arn

  role_arn=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${kb_id}" --region "${AWS_REGION}" \
    --query 'knowledgeBase.roleArn' --output text 2>/dev/null || true)
  [ -n "${role_arn}" ] && [ "${role_arn}" != "None" ] && KB_ROLE_NAME="${role_arn##*/}" || KB_ROLE_NAME=""

  supp_uri=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${kb_id}" --region "${AWS_REGION}" \
    --query 'knowledgeBase.knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration.supplementalDataStorageConfiguration.storageLocations[0].s3Location.uri' \
    --output text 2>/dev/null || true)
  if [ -n "${supp_uri}" ] && [ "${supp_uri}" != "None" ]; then
    SUPP_BUCKET="${supp_uri#s3://}"
    SUPP_BUCKET="${SUPP_BUCKET%%/*}"
  else
    SUPP_BUCKET=""
  fi

  vec_bucket_arn=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${kb_id}" --region "${AWS_REGION}" \
    --query 'knowledgeBase.storageConfiguration.s3VectorsConfiguration.vectorBucketArn' --output text 2>/dev/null || true)
  [ -n "${vec_bucket_arn}" ] && [ "${vec_bucket_arn}" != "None" ] && VECTOR_BUCKET="${vec_bucket_arn##*/}" || VECTOR_BUCKET=""

  vec_index_arn=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${kb_id}" --region "${AWS_REGION}" \
    --query 'knowledgeBase.storageConfiguration.s3VectorsConfiguration.indexArn' --output text 2>/dev/null || true)
  [ -n "${vec_index_arn}" ] && [ "${vec_index_arn}" != "None" ] && VECTOR_INDEX="${vec_index_arn##*/}" || VECTOR_INDEX=""

  ds_id=$(aws bedrock-agent list-data-sources --knowledge-base-id "${kb_id}" --region "${AWS_REGION}" \
    --query 'dataSourceSummaries[0].dataSourceId' --output text 2>/dev/null || true)
  if [ -n "${ds_id}" ] && [ "${ds_id}" != "None" ]; then
    src_bucket_arn=$(aws bedrock-agent get-data-source --knowledge-base-id "${kb_id}" --data-source-id "${ds_id}" --region "${AWS_REGION}" \
      --query 'dataSource.dataSourceConfiguration.s3Configuration.bucketArn' --output text 2>/dev/null || true)
    [ -n "${src_bucket_arn}" ] && [ "${src_bucket_arn}" != "None" ] && SOURCE_BUCKET="${src_bucket_arn##*:}" || SOURCE_BUCKET=""
  else
    SOURCE_BUCKET=""
  fi
}

# Check whether an existing Bedrock Knowledge Base should be reused (via config.env
# KB_ID / KB_NAME, or by discovering an ACTIVE KB matching ${FULL_PREFIX}-kb-*).
resolve_existing_knowledge_base() {
  KB_REUSED="false"
  KB_MANAGED="true"

  if [ -n "${KB_ID:-}" ]; then
    local kb_status kb_found_name
    kb_status=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" \
      --query 'knowledgeBase.status' --output text 2>/dev/null || true)
    if [ "${kb_status}" = "ACTIVE" ]; then
      kb_found_name=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" \
        --query 'knowledgeBase.name' --output text 2>/dev/null || true)
      [ -n "${kb_found_name}" ] && [ "${kb_found_name}" != "None" ] && KB_NAME="${kb_found_name}"
      KB_REUSED="true"
      KB_MANAGED="false"
      populate_reused_kb_metadata "${KB_ID}"
      echo "Reusing existing Bedrock Knowledge Base from config: ${KB_NAME:-$KB_ID} (${KB_ID})"
      return 0
    else
      echo "Warning: Configured KB_ID '${KB_ID}' was not found or is not ACTIVE in ${AWS_REGION} (status: ${kb_status:-not found})."
      KB_ID=""
    fi
  fi

  if [ -n "${KB_NAME:-}" ]; then
    local matched_id
    matched_id=$(aws bedrock-agent list-knowledge-bases --region "${AWS_REGION}" \
      --query "knowledgeBaseSummaries[?name=='${KB_NAME}' && status=='ACTIVE'].knowledgeBaseId | [0]" \
      --output text 2>/dev/null || true)
    if [ -n "${matched_id}" ] && [ "${matched_id}" != "None" ]; then
      KB_ID="${matched_id}"
      KB_REUSED="true"
      KB_MANAGED="false"
      populate_reused_kb_metadata "${KB_ID}"
      echo "Reusing existing Bedrock Knowledge Base by name: ${KB_NAME} (${KB_ID})"
      return 0
    else
      echo "Warning: Configured KB_NAME '${KB_NAME}' was not found or is not ACTIVE in ${AWS_REGION}. A new Knowledge Base will be created."
      KB_NAME=""
    fi
  fi

  # No configured KB found; check AWS for an existing ACTIVE KB with the same prefix.
  local existing_line existing_id existing_name reuse_reply
  existing_line=$(aws bedrock-agent list-knowledge-bases --region "${AWS_REGION}" \
    --query "knowledgeBaseSummaries[?status=='ACTIVE' && starts_with(name, '${FULL_PREFIX}-kb-')].[knowledgeBaseId,name]" \
    --output text 2>/dev/null | head -n 1 || true)

  if [ -n "${existing_line}" ] && [ "${existing_line}" != "None" ] && [ -t 0 ]; then
    read -r existing_id existing_name <<< "${existing_line}"
    if [ -n "${existing_id}" ] && [ -n "${existing_name}" ]; then
      echo ""
      echo "Found existing ACTIVE Knowledge Base: ${existing_name} (${existing_id})"
      read -r -p "Reuse this Knowledge Base to skip re-ingestion & token costs? [Y/n]: " reuse_reply
      reuse_reply=$(echo "${reuse_reply:-y}" | tr '[:upper:]' '[:lower:]')
      if [[ "${reuse_reply}" == "y" || "${reuse_reply}" == "yes" ]]; then
        KB_ID="${existing_id}"
        KB_NAME="${existing_name}"
        KB_REUSED="true"
        KB_MANAGED="false"
        populate_reused_kb_metadata "${KB_ID}"
        echo "Reusing existing Bedrock Knowledge Base: ${KB_NAME} (${KB_ID})"
        return 0
      fi
    fi
  fi
}

deploy_knowledge_base() {
  if [ "${KB_REUSED:-false}" = "true" ]; then
    echo "=== 3-4. Skipping Knowledge Base creation & BDA ingestion (reusing ${KB_NAME:-$KB_ID} / ${KB_ID}) ==="
    return 0
  fi

  echo "=== 3. Creating IAM Role for Bedrock Knowledge Base + BDA ==="
  cat > /tmp/kb-trust.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "${ACCOUNT_ID}"},
      "ArnLike": {"aws:SourceArn": "arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:knowledge-base/*"}
    }
  }]
}
EOT

  cat > /tmp/kb-policy.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeDataAutomationAsync", "bedrock:GetDataAutomationStatus"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${SOURCE_BUCKET}",
        "arn:aws:s3:::${SOURCE_BUCKET}/*",
        "arn:aws:s3:::${SUPP_BUCKET}",
        "arn:aws:s3:::${SUPP_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3vectors:*"],
      "Resource": ["${VECTOR_BUCKET_ARN}", "${VECTOR_INDEX_ARN}"]
    }
  ]
}
EOT

  KB_ROLE_ARN=$(create_role_with_inline_policy "${KB_ROLE_NAME}" "/tmp/kb-trust.json" "KBInlinePolicy" "/tmp/kb-policy.json")
  echo "Waiting 10s for IAM role propagation..."
  sleep 10

  echo "=== 4. Creating Bedrock Knowledge Base & BDA Data Source ==="
  KB_ID=$(aws bedrock-agent create-knowledge-base \
    --name "${KB_NAME}" \
    --role-arn "${KB_ROLE_ARN}" \
    --knowledge-base-configuration "{
      \"type\": \"VECTOR\",
      \"vectorKnowledgeBaseConfiguration\": {
        \"embeddingModelArn\": \"arn:aws:bedrock:${AWS_REGION}::foundation-model/amazon.titan-embed-text-v2:0\",
        \"supplementalDataStorageConfiguration\": {
          \"storageLocations\": [{
            \"type\": \"S3\",
            \"s3Location\": {\"uri\": \"s3://${SUPP_BUCKET}/\"}
          }]
        }
      }
    }" \
    --storage-configuration "{
      \"type\": \"S3_VECTORS\",
      \"s3VectorsConfiguration\": {
        \"vectorBucketArn\": \"${VECTOR_BUCKET_ARN}\",
        \"indexArn\": \"${VECTOR_INDEX_ARN}\"
      }
    }" \
    --tags "$(tags_kv)" \
    --query 'knowledgeBase.knowledgeBaseId' --output text --region "${AWS_REGION}")

  DS_ID=$(aws bedrock-agent create-data-source \
    --knowledge-base-id "${KB_ID}" \
    --name "whitepapers-bda-source" \
    --data-source-configuration "{
      \"type\": \"S3\",
      \"s3Configuration\": {\"bucketArn\": \"arn:aws:s3:::${SOURCE_BUCKET}\"}
    }" \
    --vector-ingestion-configuration '{
      "parsingConfiguration": {
        "parsingStrategy": "BEDROCK_DATA_AUTOMATION"
      }
    }' \
    --query 'dataSource.dataSourceId' --output text --region "${AWS_REGION}")

  if [ -d "./app_docs" ] && [ -n "$(find ./app_docs -maxdepth 1 -type f ! -name '.gitkeep')" ]; then
    JOB_ID=$(aws bedrock-agent start-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --query 'ingestionJob.ingestionJobId' --output text --region "${AWS_REGION}")
    echo "Waiting for BDA ingestion job (${JOB_ID}) to complete..."
    for _ in $(seq 1 30); do
      JOB_STATUS=$(aws bedrock-agent get-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --ingestion-job-id "${JOB_ID}" --query 'ingestionJob.status' --output text --region "${AWS_REGION}")
      if [ "${JOB_STATUS}" = "COMPLETE" ]; then
        echo "BDA ingestion complete!"
        break
      elif [ "${JOB_STATUS}" = "FAILED" ]; then
        echo "Warning: BDA ingestion job failed. Check Bedrock Knowledge Base console for details."
        break
      fi
      sleep 10
    done
  fi
}

teardown_knowledge_base() {
  if [ "${KEEP_KB:-false}" = "true" ]; then
    echo "Preserving Bedrock Knowledge Base (${KB_NAME:-$KB_ID}) & IAM Role (${KB_ROLE_NAME:-unknown})."
    return 0
  fi

  echo "Deleting Bedrock Knowledge Base & IAM Role..."
  [ -n "${KB_ID:-}" ] && aws bedrock-agent delete-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" || true
  delete_iam_role "${KB_ROLE_NAME:-}"
}
