# Running `deploy.sh` and `teardown.sh`

This guide covers how to run the deployment and teardown scripts either **locally** or in **AWS CloudShell** (`eu-west-1`).

---

## 1. Prerequisites

1. **AWS CLI v2** installed and authenticated (not needed if using AWS CloudShell):
   ```bash
   # Install AWS CLI v2 on Linux (x86_64) if `aws` is not found
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
   unzip /tmp/awscliv2.zip -d /tmp
   sudo /tmp/aws/install
   aws --version
   ```
   Authenticate with your AWS account:
   ```bash
   aws configure        # or: aws sso login
   aws sts get-caller-identity
   ```
2. **Billing & Guardrail:**
   - Ensure your AWS account has a valid payment method under **Billing and Cost Management → Payment preferences**.
   - Ensure Bedrock Guardrail `xojv3g7paumh` exists in `eu-west-1` (or uncomment the `create-guardrail` block in `deploy.sh`).
3. **PDF documents:** Place 1–2 short PDFs in `docs/`.

---

## 2. Option A — Run Locally

```bash
cd /home/reg/Coding/AWS_chatbot_experiment

# 1. Deploy (prompts for stage: dev, staging, or prod [default: prod])
./deploy.sh
# Or pass the stage directly without prompting:
# ./deploy.sh dev
```

`deploy.sh` creates all resources in `eu-west-1`, starts the BDA ingestion job, writes state to `.env.lab`, and prints `export RAG_API_URL=...` and `export RAG_API_KEY=...`.

### Wait for Document Ingestion (1–3 minutes)
Check that the Knowledge Base sync has completed before chatting:
```bash
source .env.lab
aws bedrock-agent list-data-sources --knowledge-base-id "${KB_ID}" --region "${AWS_REGION}" --query 'dataSourceSummaries[0].dataSourceId' --output text
```
*(Or check **Amazon Bedrock → Knowledge Bases** in `eu-west-1` until the data source status is **Complete**.)*

### Start Chatting
Copy and run the two `export` lines printed by `./deploy.sh`, then launch the CLI:
```bash
export RAG_API_URL="https://<api-id>.execute-api.eu-west-1.amazonaws.com/<stage>/chat"
export RAG_API_KEY="<your-api-key>"
python3 chat_cli.py
```

### Tear Down
When finished, remove all resources created by `deploy.sh` (preserves Guardrail `xojv3g7paumh` by default):
```bash
./teardown.sh
```

---

## 3. Option B — Run in AWS CloudShell (`eu-west-1`)

If you don't want to install the AWS CLI locally:

1. Open **AWS CloudShell** in the AWS Console (top-right region set to **`eu-west-1`**).
2. Clone or update the repo:
   ```bash
   git clone https://github.com/revhawk/AWS_Chatbot_experiment.git
   cd AWS_Chatbot_experiment
   ```
3. Upload your PDFs into `docs/` (CloudShell **Actions → Upload file**), then run:
   ```bash
   ./deploy.sh
   ```
4. Copy the printed `export RAG_API_URL=...` and `export RAG_API_KEY=...` into your **local terminal** and run `python3 chat_cli.py`.
5. When done, run `./teardown.sh` in CloudShell.

---

## 4. Checking Stages

- **Current deployed stage in `.env.lab`:**
  ```bash
  grep STAGE .env.lab
  ```
- **List all stages on the deployed API Gateway:**
  ```bash
  source .env.lab
  aws apigateway get-stages --rest-api-id "${API_ID}" --region "${AWS_REGION}" --query 'item[].stageName' --output table
  ```
- **Multiple stages:** `./deploy.sh` overwrites `.env.lab` on each run. Run `./teardown.sh` before re-deploying, or back up `.env.lab` per stage (e.g. `cp .env.lab .env.lab.dev`).
