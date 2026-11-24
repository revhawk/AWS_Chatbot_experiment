#!/usr/bin/env bash
# DynamoDB, Lambda + IAM Role, and API Gateway + API Key + Usage Plan module

resolve_existing_ddb_table() {
  DDB_REUSED="false"
  local existing_table reuse_reply
  existing_table=$(aws dynamodb list-tables --region "${AWS_REGION}" \
    --query "TableNames[?starts_with(@, '${FULL_PREFIX}-history-')]" \
    --output text 2>/dev/null | awk '{print $1}' || true)

  if [ -n "${existing_table}" ] && [ "${existing_table}" != "None" ] && [ -t 0 ]; then
    echo ""
    echo "Found existing DynamoDB history table from a previous run: ${existing_table}"
    read -r -p "Reuse this DynamoDB table to keep existing chat history? [Y/n]: " reuse_reply
    reuse_reply=$(echo "${reuse_reply:-y}" | tr '[:upper:]' '[:lower:]')
    if [[ "${reuse_reply}" == "y" || "${reuse_reply}" == "yes" ]]; then
      DDB_TABLE="${existing_table}"
      DDB_REUSED="true"
      echo "Reusing existing DynamoDB table: ${DDB_TABLE}"
    fi
  fi
}

deploy_compute_api() {
  if [ "${DDB_REUSED:-false}" = "true" ]; then
    echo "=== 5. Reusing existing DynamoDB Table (${DDB_TABLE}) ==="
  else
    echo "=== 5. Creating DynamoDB Table (On-Demand, AWS Owned Key) ==="
    # shellcheck disable=SC2046
    aws dynamodb create-table \
      --table-name "${DDB_TABLE}" \
      --attribute-definitions AttributeName=session_id,AttributeType=S AttributeName=timestamp,AttributeType=S \
      --key-schema AttributeName=session_id,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST \
      --tags $(tags_iam) \
      --region "${AWS_REGION}" >/dev/null
  fi

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

  cat > /tmp/lambda-policy.json <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:RetrieveAndGenerate", "bedrock:Retrieve", "bedrock:InvokeModel", "bedrock:GetInferenceProfile", "bedrock:ApplyGuardrail"],
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

  LAMBDA_ROLE_ARN=$(create_role_with_inline_policy "${LAMBDA_ROLE_NAME}" "/tmp/lambda-trust.json" "LambdaRagPolicy" "/tmp/lambda-policy.json" "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
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
    --environment "Variables={KB_ID=${KB_ID},KB_MODE=${KB_MODE},MODEL_ARN=arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:inference-profile/eu.amazon.nova-micro-v1:0,GUARDRAIL_ID=${GUARDRAIL_ID},GUARDRAIL_VERSION=${GUARDRAIL_VERSION},TABLE_NAME=${DDB_TABLE},MEMORY_MODE=${MEMORY_MODE}}" \
    --tags "$(tags_kv)" \
    --query 'FunctionArn' --output text --region "${AWS_REGION}")

  echo "=== 7. Creating API Gateway REST API + API Key ==="
  API_ID=$(aws apigateway create-rest-api --name "${API_NAME}" --endpoint-configuration types=REGIONAL --tags "$(tags_kv)" --query 'id' --output text --region "${AWS_REGION}")
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
}

teardown_compute_api() {
  echo "Deleting API Gateway, Usage Plan & API Key..."
  aws apigateway delete-usage-plan-key --usage-plan-id "${PLAN_ID}" --key-id "${API_KEY_ID}" --region "${AWS_REGION}" || true
  aws apigateway update-usage-plan --usage-plan-id "${PLAN_ID}" --patch-operations "op=remove,path=/apiStages,value=${API_ID}:${STAGE:-prod}" --region "${AWS_REGION}" >/dev/null || true
  aws apigateway delete-rest-api --rest-api-id "${API_ID}" --region "${AWS_REGION}" || true
  aws apigateway delete-usage-plan --usage-plan-id "${PLAN_ID}" --region "${AWS_REGION}" || true
  aws apigateway delete-api-key --api-key "${API_KEY_ID}" --region "${AWS_REGION}" || true

  echo "Deleting Lambda Function, Log Group & IAM Role..."
  aws lambda delete-function --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" || true
  aws logs delete-log-group --log-group-name "/aws/lambda/${LAMBDA_NAME}" --region "${AWS_REGION}" || true
  delete_iam_role "${LAMBDA_ROLE_NAME}"

  echo "Deleting DynamoDB Table..."
  aws dynamodb delete-table --table-name "${DDB_TABLE}" --region "${AWS_REGION}" >/dev/null || true
}
