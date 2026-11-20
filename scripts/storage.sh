#!/usr/bin/env bash
# S3 source/supplemental buckets and S3 Vectors bucket/index module

deploy_storage() {
  echo "=== 1. Creating S3 Source & Supplemental Buckets (SSE-S3 Managed Encryption) ==="
  aws s3 mb "s3://${SOURCE_BUCKET}" --region "${AWS_REGION}"
  aws s3 mb "s3://${SUPP_BUCKET}" --region "${AWS_REGION}"
  aws s3api put-bucket-tagging --bucket "${SOURCE_BUCKET}" --tagging "$(tags_s3)" --region "${AWS_REGION}"
  aws s3api put-bucket-tagging --bucket "${SUPP_BUCKET}" --tagging "$(tags_s3)" --region "${AWS_REGION}"

  if [ -d "./app_docs" ] && [ -n "$(find ./app_docs -maxdepth 1 -type f ! -name '.gitkeep')" ]; then
    aws s3 cp ./app_docs/ "s3://${SOURCE_BUCKET}/" --recursive --exclude ".gitkeep"
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
}

teardown_storage() {
  echo "Deleting S3 Vectors Index & Bucket..."
  aws s3vectors delete-index --vector-bucket-name "${VECTOR_BUCKET}" --index-name "${VECTOR_INDEX}" --region "${AWS_REGION}" || true
  aws s3vectors delete-vector-bucket --vector-bucket-name "${VECTOR_BUCKET}" --region "${AWS_REGION}" || true

  echo "Emptying & Deleting S3 Buckets..."
  aws s3 rb "s3://${SOURCE_BUCKET}" --force --region "${AWS_REGION}" || true
  aws s3 rb "s3://${SUPP_BUCKET}" --force --region "${AWS_REGION}" || true
}
