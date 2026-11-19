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
aws apigateway delete-usage-plan --usage-plan-id "${PLAN_ID}" --region "${AWS_REGION}" || true
aws apigateway delete-api-key --api-key "${API_KEY_ID}" --region "${AWS_REGION}" || true
aws apigateway delete-rest-api --rest-api-id "${API_ID}" --region "${AWS_REGION}" || true

echo "2. Deleting Lambda Function & IAM Role..."
aws lambda delete-function --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" || true
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

# --- Guardrail Cleanup (Preserved by Default) ---
# Why preserved:
#   1. Guardrail xojv3g7paumh existed before this experiment and is reused across labs.
#   2. Bedrock Guardrails have $0 idle/storage cost (billed only per text unit evaluated).
#
# Future instructions:
#   - If you switched deploy.sh to create a new Guardrail per run, uncomment the generic
#     command below (uses GUARDRAIL_ID saved in .env.lab):
#     aws bedrock delete-guardrail --guardrail-identifier "${GUARDRAIL_ID}" --region "${AWS_REGION}" || true
#
#   - Or to explicitly delete the original pre-existing Guardrail (note: deploy.sh expects it
#     unless you also switch deploy.sh to create-guardrail):
#     aws bedrock delete-guardrail --guardrail-identifier "xojv3g7paumh" --region "${AWS_REGION}" || true

rm -f .env.lab
echo "=== Teardown Complete! Guardrail (${GUARDRAIL_ID:-xojv3g7paumh}) was preserved. ==="
