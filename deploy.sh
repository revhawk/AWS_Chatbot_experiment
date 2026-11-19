#!/usr/bin/env bash
set -euo pipefail

# Ask which API Gateway stage to deploy to (or accept as first argument: ./deploy.sh dev)
STAGE="${1:-}"
if [ -z "${STAGE}" ]; then
  read -r -p "Enter API Gateway stage to deploy to (e.g. dev, staging, prod) [prod]: " STAGE
  STAGE="${STAGE:-prod}"
fi

if [[ ! "${STAGE}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: Stage name '${STAGE}' must contain only letters, numbers, hyphens, or underscores."
  exit 1
fi
echo "Deploying to stage: ${STAGE}"

export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SUFFIX=$(date +%s)

# --- Guardrail Configuration ---
# By default, this lab reuses the pre-existing Bedrock Guardrail (xojv3g7paumh, $0 idle cost).
# Future instructions: If you want deploy.sh to create a brand-new Guardrail for each run:
#   1. Comment out GUARDRAIL_ID="xojv3g7paumh" below.
#   2. Uncomment the `aws bedrock create-guardrail` block below.
#   3. Optionally uncomment the Guardrail delete line in teardown.sh so it gets cleaned up.
GUARDRAIL_ID="xojv3g7paumh"
GUARDRAIL_VERSION="DRAFT"

# GUARDRAIL_ID=$(aws bedrock create-guardrail \
#   --name "bedrock-rag-guardrail-${SUFFIX}" \
#   --description "RAG chatbot guardrail for prompt/response safety" \
#   --blocked-input-messaging "Sorry, I cannot process this request due to safety policies." \
#   --blocked-outputs-messaging "Sorry, I cannot provide that response due to safety policies." \
#   --content-policy-config '{
#     "filtersConfig": [
#       {"type": "SEXUAL", "inputStrength": "HIGH", "outputStrength": "HIGH"},
#       {"type": "VIOLENCE", "inputStrength": "HIGH", "outputStrength": "HIGH"},
#       {"type": "HATE", "inputStrength": "HIGH", "outputStrength": "HIGH"},
#       {"type": "INSULTS", "inputStrength": "HIGH", "outputStrength": "HIGH"},
#       {"type": "MISCONDUCT", "inputStrength": "HIGH", "outputStrength": "HIGH"},
#       {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE"}
#     ]
#   }' \
#   --query 'guardrailId' --output text --region "${AWS_REGION}")

SOURCE_BUCKET="bedrock-rag-docs-${ACCOUNT_ID}-${SUFFIX}"
SUPP_BUCKET="bedrock-rag-bda-supp-${ACCOUNT_ID}-${SUFFIX}"
VECTOR_BUCKET="bedrock-rag-vec-${SUFFIX}"
VECTOR_INDEX="whitepapers-index"
KB_NAME="whitepapers-bda-kb-${SUFFIX}"
KB_ROLE_NAME="BedrockKBRole-${SUFFIX}"
LAMBDA_ROLE_NAME="BedrockRagLambdaRole-${SUFFIX}"
LAMBDA_NAME="bedrock-rag-chat-${SUFFIX}"
DDB_TABLE="BedrockChatHistory-${SUFFIX}"
API_NAME="bedrock-rag-api-${SUFFIX}"

echo "=== 1. Creating S3 Source & Supplemental Buckets (SSE-S3 Managed Encryption) ==="
aws s3 mb "s3://${SOURCE_BUCKET}" --region "${AWS_REGION}"
aws s3 mb "s3://${SUPP_BUCKET}" --region "${AWS_REGION}"

if [ -d "./docs" ] && [ -n "$(find ./docs -maxdepth 1 -type f ! -name '.gitkeep')" ]; then
  aws s3 cp ./docs/ "s3://${SOURCE_BUCKET}/" --recursive --exclude ".gitkeep"
fi

echo "=== 2. Creating S3 Vectors Bucket & Index (1024 dims for Titan Embed v2) ==="
aws s3vectors create-vector-bucket \
  --vector-bucket-name "${VECTOR_BUCKET}" \
  --encryption-configuration '{"sseType":"AES256"}' \
  --region "${AWS_REGION}"

aws s3vectors create-index \
  --vector-bucket-name "${VECTOR_BUCKET}" \
  --index-name "${VECTOR_INDEX}" \
  --data-type float32 \
  --dimension 1024 \
  --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT","AMAZON_BEDROCK_METADATA"]}' \
  --encryption-configuration '{"sseType":"AES256"}' \
  --region "${AWS_REGION}"

VECTOR_BUCKET_ARN=$(aws s3vectors get-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" --query 'vectorBucket.vectorBucketArn' --output text --region "${AWS_REGION}")
VECTOR_INDEX_ARN=$(aws s3vectors get-index --vector-bucket-name "${VECTOR_BUCKET}" --index-name "${VECTOR_INDEX}" --query 'index.indexArn' --output text --region "${AWS_REGION}")

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

KB_ROLE_ARN=$(aws iam create-role --role-name "${KB_ROLE_NAME}" --assume-role-policy-document file:///tmp/kb-trust.json --query 'Role.Arn' --output text)

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

aws iam put-role-policy --role-name "${KB_ROLE_NAME}" --policy-name "KBInlinePolicy" --policy-document file:///tmp/kb-policy.json
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

if [ -d "./docs" ] && [ -n "$(find ./docs -maxdepth 1 -type f ! -name '.gitkeep')" ]; then
  aws bedrock-agent start-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --region "${AWS_REGION}" >/dev/null
  echo "Started BDA ingestion job for uploaded documents."
fi

echo "=== 5. Creating DynamoDB Table (On-Demand, AWS Owned Key) ==="
aws dynamodb create-table \
  --table-name "${DDB_TABLE}" \
  --attribute-definitions AttributeName=session_id,AttributeType=S AttributeName=timestamp,AttributeType=S \
  --key-schema AttributeName=session_id,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region "${AWS_REGION}" >/dev/null

echo "=== 6. Creating Lambda Execution Role & Function ==="
cat > /tmp/lambda-trust.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOT

LAMBDA_ROLE_ARN=$(aws iam create-role --role-name "${LAMBDA_ROLE_NAME}" --assume-role-policy-document file:///tmp/lambda-trust.json --query 'Role.Arn' --output text)
aws iam attach-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

cat > /tmp/lambda-policy.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:RetrieveAndGenerate", "bedrock:Retrieve", "bedrock:InvokeModel", "bedrock:ApplyGuardrail"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:Query"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DDB_TABLE}"
    }
  ]
}
EOT

aws iam put-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name "LambdaRagPolicy" --policy-document file:///tmp/lambda-policy.json
sleep 10

zip -j /tmp/lambda.zip lambda/handler.py >/dev/null

LAMBDA_ARN=$(aws lambda create-function \
  --function-name "${LAMBDA_NAME}" \
  --runtime python3.12 \
  --role "${LAMBDA_ROLE_ARN}" \
  --handler handler.lambda_handler \
  --zip-file fileb:///tmp/lambda.zip \
  --timeout 30 \
  --memory-size 256 \
  --environment "Variables={KB_ID=${KB_ID},MODEL_ARN=arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:inference-profile/eu.amazon.nova-micro-v1:0,GUARDRAIL_ID=${GUARDRAIL_ID},GUARDRAIL_VERSION=${GUARDRAIL_VERSION},TABLE_NAME=${DDB_TABLE}}" \
  --query 'FunctionArn' --output text --region "${AWS_REGION}")

echo "=== 7. Creating API Gateway REST API + API Key ==="
API_ID=$(aws apigateway create-rest-api --name "${API_NAME}" --endpoint-configuration types=REGIONAL --query 'id' --output text --region "${AWS_REGION}")
ROOT_ID=$(aws apigateway get-resources --rest-api-id "${API_ID}" --query 'items[0].id' --output text --region "${AWS_REGION}")
RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "${API_ID}" --parent-id "${ROOT_ID}" --path-part "chat" --query 'id' --output text --region "${AWS_REGION}")

aws apigateway put-method --rest-api-id "${API_ID}" --resource-id "${RESOURCE_ID}" --http-method POST --authorization-type NONE --api-key-required --region "${AWS_REGION}" >/dev/null
aws apigateway put-integration --rest-api-id "${API_ID}" --resource-id "${RESOURCE_ID}" --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" --region "${AWS_REGION}" >/dev/null

aws lambda add-permission --function-name "${LAMBDA_NAME}" --statement-id "apigw-invoke" --action "lambda:InvokeFunction" --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/chat" --region "${AWS_REGION}" >/dev/null

aws apigateway create-deployment --rest-api-id "${API_ID}" --stage-name "${STAGE}" --region "${AWS_REGION}" >/dev/null

API_KEY_ID=$(aws apigateway create-api-key --name "${API_NAME}-key" --enabled --query 'id' --output text --region "${AWS_REGION}")
API_KEY_VAL=$(aws apigateway get-api-key --api-key "${API_KEY_ID}" --include-value --query 'value' --output text --region "${AWS_REGION}")
PLAN_ID=$(aws apigateway create-usage-plan --name "${API_NAME}-plan" --throttle rateLimit=5,burstLimit=10 --quota limit=1000,period=DAY --api-stages apiId="${API_ID}",stage="${STAGE}" --query 'id' --output text --region "${AWS_REGION}")
aws apigateway create-usage-plan-key --usage-plan-id "${PLAN_ID}" --key-id "${API_KEY_ID}" --key-type API_KEY --region "${AWS_REGION}" >/dev/null

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE}/chat"

cat > .env.lab <<EOT
AWS_REGION=${AWS_REGION}
STAGE=${STAGE}
SOURCE_BUCKET=${SOURCE_BUCKET}
SUPP_BUCKET=${SUPP_BUCKET}
VECTOR_BUCKET=${VECTOR_BUCKET}
VECTOR_INDEX=${VECTOR_INDEX}
KB_ID=${KB_ID}
GUARDRAIL_ID=${GUARDRAIL_ID}
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
