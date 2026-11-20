#!/usr/bin/env bash
# Bedrock Knowledge Base + BDA Data Source + IAM Role module

deploy_knowledge_base() {
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
    aws bedrock-agent start-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --region "${AWS_REGION}" >/dev/null
    echo "Started BDA ingestion job for uploaded documents."
  fi
}

teardown_knowledge_base() {
  echo "Deleting Bedrock Knowledge Base & IAM Role..."
  aws bedrock-agent delete-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" || true
  delete_iam_role "${KB_ROLE_NAME}"
}
