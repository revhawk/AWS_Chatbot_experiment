#!/usr/bin/env bash
# Post-deploy Terraform build verification:
#   1. Verifies Internal ALB target groups (API + SPA PrivateLink ENIs) are healthy
#   2. Verifies Bedrock Knowledge Base is ACTIVE
#   3. Uploads a sample test document to S3 and runs a KB ingestion sync job until COMPLETE
#   4. Runs a live Bedrock KB retrieve query to confirm S3 Vectors indexing works end-to-end
#
# Usage (from repo root or inside container at /work):
#   ./scripts/smoke_test_tf.sh
#
# Optional env overrides (auto-read from Terraform outputs if unset):
#   AWS_REGION, NAME_PREFIX, SOURCE_BUCKET, KB_ID, DATA_SOURCE_ID, RESOURCE_GROUP_NAME

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-1}"
PERSISTENT_DIR="${PERSISTENT_DIR:-infra/terraform/stacks/persistent}"
APP_DIR="${APP_DIR:-infra/terraform/stacks/app}"
NAME_PREFIX="${NAME_PREFIX:-lab-bedrock-rag-prod}"
MAX_INGESTION_POLLS="${MAX_INGESTION_POLLS:-24}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

tf_out() {
  local dir="$1" key="$2"
  terraform -chdir="${dir}" output -raw "${key}" 2>/dev/null || true
}

SOURCE_BUCKET="${SOURCE_BUCKET:-$(tf_out "${PERSISTENT_DIR}" source_bucket)}"
KB_ID="${KB_ID:-$(tf_out "${PERSISTENT_DIR}" kb_id)}"
DATA_SOURCE_ID="${DATA_SOURCE_ID:-$(tf_out "${PERSISTENT_DIR}" data_source_id)}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-$(tf_out "${APP_DIR}" resource_group_name)}"

if [ -z "${SOURCE_BUCKET}" ] || [ -z "${KB_ID}" ] || [ -z "${DATA_SOURCE_ID}" ]; then
  echo "ERROR: SOURCE_BUCKET, KB_ID, and DATA_SOURCE_ID must be set or available via Terraform outputs." >&2
  exit 1
fi

echo "=== 1. Checking Internal ALB Target Group Health ==="
for tg in "${NAME_PREFIX}-api-tg" "${NAME_PREFIX}-spa-tg"; do
  tg_arn=$(aws elbv2 describe-target-groups --no-cli-pager --region "${AWS_REGION}" \
    --names "${tg}" --query 'TargetGroups[0].TargetGroupArn' --output text)
  states=$(aws elbv2 describe-target-health --no-cli-pager --region "${AWS_REGION}" \
    --target-group-arn "${tg_arn}" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  echo "  ${tg}: ${states}"
  if [ -z "${states}" ]; then
    echo "ERROR: Target group ${tg} has no registered targets." >&2
    exit 1
  fi
  for st in ${states}; do
    if [ "${st}" != "healthy" ]; then
      echo "ERROR: Target group ${tg} has unhealthy target state: ${st}" >&2
      exit 1
    fi
  done
done

echo "=== 2. Checking Knowledge Base Status ==="
kb_status=$(aws bedrock-agent get-knowledge-base --no-cli-pager --region "${AWS_REGION}" \
  --knowledge-base-id "${KB_ID}" --query 'knowledgeBase.status' --output text)
echo "  Knowledge Base ${KB_ID}: ${kb_status}"
if [ "${kb_status}" != "ACTIVE" ]; then
  echo "ERROR: Knowledge Base ${KB_ID} is not ACTIVE (status=${kb_status})." >&2
  exit 1
fi

echo "=== 3. Uploading Sample Document & Running KB Ingestion Sync ==="
tmp_doc=$(mktemp /tmp/kb-smoke-XXXXXX.txt)
trap 'rm -f "${tmp_doc}"' EXIT
cat >"${tmp_doc}" <<'EOF'
The AWS Bedrock RAG Assistant runs in eu-west-1 inside a zero-internet private VPC using AWS PrivateLink, S3 Vectors, and Bedrock Guardrails.
EOF

aws s3 cp --no-cli-pager "${tmp_doc}" "s3://${SOURCE_BUCKET}/smoke_test_sample.txt" --region "${AWS_REGION}"

job_id=$(aws bedrock-agent start-ingestion-job --no-cli-pager --region "${AWS_REGION}" \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DATA_SOURCE_ID}" \
  --query 'ingestionJob.ingestionJobId' --output text)
echo "  Started ingestion job: ${job_id}"

job_status="STARTING"
poll=0
while [ "${poll}" -lt "${MAX_INGESTION_POLLS}" ]; do
  job_status=$(aws bedrock-agent get-ingestion-job --no-cli-pager --region "${AWS_REGION}" \
    --knowledge-base-id "${KB_ID}" \
    --data-source-id "${DATA_SOURCE_ID}" \
    --ingestion-job-id "${job_id}" \
    --query 'ingestionJob.status' --output text)
  echo "  Ingestion status: ${job_status}"
  if [ "${job_status}" = "COMPLETE" ]; then
    break
  fi
  if [ "${job_status}" = "FAILED" ]; then
    echo "ERROR: Ingestion job ${job_id} FAILED." >&2
    exit 1
  fi
  poll=$((poll + 1))
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [ "${job_status}" != "COMPLETE" ]; then
  echo "ERROR: Ingestion job ${job_id} did not complete in time (last status=${job_status})." >&2
  exit 1
fi

echo "=== 4. Verifying Live KB Retrieval (S3 Vectors) ==="
hit_count=$(aws bedrock-agent-runtime retrieve --no-cli-pager --region "${AWS_REGION}" \
  --knowledge-base-id "${KB_ID}" \
  --retrieval-query '{"text":"Where does the AWS Bedrock RAG Assistant run?"}' \
  --query 'length(retrievalResults)' --output text)
echo "  Retrieved chunks: ${hit_count}"
if [ "${hit_count}" = "0" ] || [ -z "${hit_count}" ]; then
  echo "ERROR: Knowledge Base retrieve returned 0 chunks." >&2
  exit 1
fi

if [ -n "${RESOURCE_GROUP_NAME}" ]; then
  echo "=== 5. Verifying Resource Group (${RESOURCE_GROUP_NAME}) ==="
  rg_count=$(aws resource-groups list-group-resources --no-cli-pager --region "${AWS_REGION}" \
    --group-name "${RESOURCE_GROUP_NAME}" --query 'length(Resources)' --output text)
  echo "  Resource Group members: ${rg_count}"
fi

echo "=== Smoke Test PASSED ==="
