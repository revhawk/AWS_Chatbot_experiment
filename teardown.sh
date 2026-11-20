#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env.lab ]; then
  echo "Error: .env.lab not found. Nothing to tear down."
  exit 1
fi

source .env.lab
echo "=== Starting Teardown in ${AWS_REGION} ==="

echo "1. Deleting API Gateway, Usage Plan & API Key..."
aws apigateway delete-usage-plan-key --usage-plan-id "${PLAN_ID}" --key-id "${API_KEY_ID}" --region "${AWS_REGION}" || true
aws apigateway update-usage-plan --usage-plan-id "${PLAN_ID}" --patch-operations "op=remove,path=/apiStages,value=${API_ID}:${STAGE:-prod}" --region "${AWS_REGION}" >/dev/null || true
aws apigateway delete-rest-api --rest-api-id "${API_ID}" --region "${AWS_REGION}" || true
aws apigateway delete-usage-plan --usage-plan-id "${PLAN_ID}" --region "${AWS_REGION}" || true
aws apigateway delete-api-key --api-key "${API_KEY_ID}" --region "${AWS_REGION}" || true

echo "2. Deleting Lambda Function, Log Group & IAM Role..."
aws lambda delete-function --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" || true
aws logs delete-log-group --log-group-name "/aws/lambda/${LAMBDA_NAME}" --region "${AWS_REGION}" || true
aws iam detach-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" || true
aws iam delete-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name "LambdaRagPolicy" || true
aws iam delete-role --role-name "${LAMBDA_ROLE_NAME}" || true

echo "3. Deleting DynamoDB Table..."
aws dynamodb delete-table --table-name "${DDB_TABLE}" --region "${AWS_REGION}" >/dev/null || true

echo "4. Deleting Bedrock Knowledge Base & IAM Role..."
aws bedrock-agent delete-knowledge-base --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" || true
aws iam delete-role-policy --role-name "${KB_ROLE_NAME}" --policy-name "KBInlinePolicy" || true
aws iam delete-role --role-name "${KB_ROLE_NAME}" || true

echo "5. Deleting S3 Vectors Index & Bucket..."
aws s3vectors delete-index --vector-bucket-name "${VECTOR_BUCKET}" --index-name "${VECTOR_INDEX}" --region "${AWS_REGION}" || true
aws s3vectors delete-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" --region "${AWS_REGION}" || true

echo "6. Emptying & Deleting S3 Buckets..."
aws s3 rb "s3://${SOURCE_BUCKET}" --force --region "${AWS_REGION}" || true
aws s3 rb "s3://${SUPP_BUCKET}" --force --region "${AWS_REGION}" || true

echo "7. Deleting Lab Guardrail & Resource Group..."
if [ -n "${GUARDRAIL_ID:-}" ]; then
  aws bedrock delete-guardrail --guardrail-identifier "${GUARDRAIL_ID}" --region "${AWS_REGION}" || true
fi
if [ -n "${RESOURCE_GROUP_NAME:-}" ]; then
  aws resource-groups delete-group --group-name "${RESOURCE_GROUP_NAME}" --region "${AWS_REGION}" >/dev/null || true
fi

rm -f .env.lab
echo "=== Teardown Complete! ==="
