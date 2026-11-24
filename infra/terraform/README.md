# Terraform 2-Stack Deployment (Podman — Zero Host Installs)

This directory provides a 2-stack Terraform alternative to `deploy.sh` / `teardown.sh`:

- **`knowledge/` (Persistent Stack):** S3 source/supplemental buckets (`AES256`), S3 Vectors bucket/index (1024-dim cosine), KB IAM role, Bedrock Knowledge Base + BDA data source, and optional Bedrock Guardrail. Deploy once and keep across teardown cycles to avoid re-ingestion time and token costs.
- **`app/` (Ephemeral Stack):** DynamoDB table, Lambda function (`lambda/handler.py`), API Gateway (`POST /chat` + `x-api-key` + Usage Plan), and AWS Resource Group (groups both stacks via `Project` + `Stage` tags). Destroy and redeploy freely without touching your Knowledge Base.

---

## 1. Build & Enter the Podman Container (Includes AWS CLI v2 + Terraform)

```bash
podman build -t aws-rag-cli .
podman run --rm -it \
  -v "$PWD:/work:Z" \
  -v "$HOME/.aws:/root/.aws:Z" \
  -w /work \
  aws-rag-cli
aws login --remote
```

---

## 2. Deploy Stack 1 — Persistent Knowledge Base (`knowledge/`)

```bash
cd /work/infra/terraform/knowledge
cp terraform.tfvars.example terraform.tfvars   # customize as needed
terraform init
terraform plan
terraform apply
```

Upload your PDFs and run BDA ingestion once:
```bash
SOURCE_BUCKET=$(terraform output -raw source_bucket)
KB_ID=$(terraform output -raw kb_id)
DS_ID=$(terraform output -raw data_source_id)

aws s3 cp /work/app_docs/ "s3://${SOURCE_BUCKET}/" --recursive --exclude ".gitkeep"
aws bedrock-agent start-ingestion-job --knowledge-base-id "${KB_ID}" --data-source-id "${DS_ID}" --region eu-west-1
```

---

## 3. Deploy Stack 2 — Ephemeral App Stack (`app/`)

Automatically reads `kb_id` and `guardrail_id` from `../knowledge/terraform.tfstate` (or override them in `terraform.tfvars` to link an existing Managed/SharePoint KB):

```bash
cd /work/infra/terraform/app
cp terraform.tfvars.example terraform.tfvars   # customize as needed
terraform init
terraform plan
terraform apply
```

Start chatting from your host terminal:
```bash
export RAG_API_URL="$(terraform -chdir=infra/terraform/app output -raw api_url)"
export RAG_API_KEY="$(terraform -chdir=infra/terraform/app output -raw api_key)"
python3 chat_cli.py
```

---

## 4. Tear Down Without Losing Your Knowledge Base

Destroy only the ephemeral `app/` stack — your Knowledge Base, vectors, and embeddings in `knowledge/` remain untouched:

```bash
cd /work/infra/terraform/app
terraform destroy
```

To tear down everything (including the Knowledge Base and S3 Vectors):
```bash
cd /work/infra/terraform/knowledge
terraform destroy
```
