# Running `deploy.sh` and `teardown.sh`

This guide covers how to run the deployment and teardown scripts using **Podman** (recommended—no host AWS CLI install needed), **AWS CloudShell**, or a **local AWS CLI v2** install.

---

## 1. Prerequisites

- **Billing & Guardrail:**
  - Ensure your AWS account has a valid payment method under **Billing and Cost Management → Payment preferences**.
  - Ensure Bedrock Guardrail `xojv3g7paumh` exists in `eu-west-1` (or uncomment the `create-guardrail` block in `deploy.sh`).
- **PDF documents:** Place 1–2 short PDFs in `docs/` (ignored by Git via `.gitignore`).

---

## 2. Option A — Run via Podman (Recommended, Zero Host Installs)

1. Start an ephemeral `amazon/aws-cli` container mounting your project and `~/.aws`:
   ```bash
   cd /home/reg/Coding/AWS_chatbot_experiment

   podman run --rm -it --entrypoint bash \
     -v "$PWD:/work:Z" \
     -v "$HOME/.aws:/root/.aws:Z" \
     -w /work \
     docker.io/amazon/aws-cli:latest
   ```
2. Inside the container, install `zip` (vanishes on `exit`) and authenticate with temporary Console credentials (use `--remote` inside Podman so it doesn't try to redirect to `127.0.0.1` inside the container):
   ```bash
   yum install -y zip >/dev/null
   aws login --remote
   ```
   *(Or use `aws sso login` / `aws configure` if you use IAM Identity Center or IAM keys. Credentials are saved to `~/.aws` on your host.)*
3. Deploy (prompts for stage: `dev`, `staging`, or `prod` [default: `prod`], and memory mode: `single` or `multi` [default: `single`]):
   ```bash
   ./deploy.sh
   # or skip the prompts: ./deploy.sh dev multi
   ```
   - **`single`:** Each question is answered independently (no prior chat history sent; lower token cost).
   - **`multi`:** Loads the last 6 turns for the `session_id` from DynamoDB so you can ask follow-up questions.
4. Wait ~1–3 minutes for Bedrock Data Automation (BDA) ingestion to finish, then check status:
   ```bash
   source .env.lab
   DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" --region "$AWS_REGION" --query 'dataSourceSummaries[0].dataSourceId' --output text)
   aws bedrock-agent list-ingestion-jobs --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID"
   ```
   Wait until `"status": "COMPLETE"`.
5. In your **host terminal**, export the `RAG_API_URL` and `RAG_API_KEY` printed by `./deploy.sh` and chat:
   ```bash
   cd /home/reg/Coding/AWS_chatbot_experiment
   export RAG_API_URL="https://<api-id>.execute-api.eu-west-1.amazonaws.com/<stage>/chat"
   export RAG_API_KEY="<your-api-key>"
   python3 chat_cli.py
   ```
6. When finished, tear down all lab resources from inside the Podman container (preserves Guardrail `xojv3g7paumh` by default):
   ```bash
   ./teardown.sh
   exit
   ```

---

## 3. Option B — Run in AWS CloudShell (`eu-west-1`)

1. Open **AWS CloudShell** in the AWS Console (top-right region set to **`eu-west-1`**).
2. Clone or update the repo:
   ```bash
   git clone https://github.com/revhawk/AWS_Chatbot_experiment.git
   cd AWS_Chatbot_experiment
   ```
3. Upload your PDFs into `docs/` (CloudShell **Actions → Upload file**), then run `./deploy.sh`.
4. Copy the printed `export RAG_API_URL=...` and `export RAG_API_KEY=...` into your **local terminal** and run `python3 chat_cli.py`.
5. When done, run `./teardown.sh` in CloudShell.

---

## 4. Option C — Run Locally with AWS CLI v2

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
aws login              # or: aws sso login / aws configure
cd /home/reg/Coding/AWS_chatbot_experiment
./deploy.sh
```

---

## 5. Checking Stages & Logs

- **Current deployed stage in `.env.lab`:**
  ```bash
  grep STAGE .env.lab
  ```
- **List all stages on the deployed API Gateway:**
  ```bash
  source .env.lab
  aws apigateway get-stages --rest-api-id "${API_ID}" --region "${AWS_REGION}" --query 'item[].stageName' --output table
  ```
- **Tail Lambda logs:**
  ```bash
  source .env.lab
  aws logs tail /aws/lambda/$LAMBDA_NAME --since 5m
  ```

---

## 6. Key Fixes Included

- **`bedrock:GetInferenceProfile` in `LambdaRagPolicy` (`deploy.sh`):** Required when calling `RetrieveAndGenerate` with an inference profile ARN (`eu.amazon.nova-micro-v1:0`).
- **Dual-mode Lambda (`lambda/handler.py`):** Supports both S3 Vectors Knowledge Bases (`KB_MODE=vector`, default for `deploy.sh` via `retrieve_and_generate`) and Console Managed Knowledge Bases (`KB_MODE=managed` via `retrieve` + `converse`).
- **Podman `aws login --remote`:** Bypasses container `127.0.0.1` callback issues when authenticating from a host browser.
