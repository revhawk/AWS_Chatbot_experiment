# Running `deploy.sh` and `teardown.sh`

This guide covers how to run the deployment and teardown scripts using **Podman** (recommended—no host AWS CLI install needed), **AWS CloudShell**, or a **local AWS CLI v2** install.

---

## 1. Prerequisites

- **Billing & Guardrail:**
  - Ensure your AWS account has a valid payment method under **Billing and Cost Management → Payment preferences**.
  - By default, `./deploy.sh` creates a new Bedrock Guardrail (`${FULL_PREFIX}-guardrail-${SUFFIX}`) or offers to reuse one from a previous run. To always reuse and preserve a specific existing guardrail (e.g. `xojv3g7paumh`), set `GUARDRAIL_ID="xojv3g7paumh"` in `config.env`.
- **PDF documents:** Place 1–2 short PDFs in `app_docs/` (ignored by Git via `.gitignore`).

---

## 2. Option A — Run via Podman (Recommended, Zero Host Installs)

1. Clone the repository (if you haven't already) and enter the project folder:
   ```bash
   git clone https://github.com/revhawk/AWS_Chatbot_experiment.git
   cd AWS_Chatbot_experiment
   ```
2. Build the Podman image once (includes AWS CLI v2 + `zip`):
   ```bash
   podman build -t aws-rag-cli .
   ```
3. Start the ephemeral container mounting your project and `~/.aws`:
   ```bash
   podman run --rm -it \
     -v "$PWD:/work:Z" \
     -v "$HOME/.aws:/root/.aws:Z" \
     -w /work \
     aws-rag-cli
   ```
4. Inside the container, authenticate with temporary Console credentials (use `--remote` inside Podman so it doesn't try to redirect to `127.0.0.1` inside the container):
   ```bash
   aws login --remote
   ```
   *(Or use `aws sso login` / `aws configure` if you use IAM Identity Center or IAM keys. Credentials are saved to `~/.aws` on your host.)*
5. Deploy (shows a **Pre-Deploy Check & Build Plan** for confirmation, deploys the stack, and runs a **Post-Deploy Smoke Test** covering a RAG sample query plus guardrail checks for custom word blocking, prompt attacks, and PII anonymization):
   ```bash
   ./deploy.sh
   # or skip prompts / auto-approve:
   ./deploy.sh --yes dev multi
   # or skip the post-deploy sample question:
   ./deploy.sh --skip-smoke-test
   ```
   - **`KB_MODE` (`config.env`):** `vector` (default, S3 Vectors + `RetrieveAndGenerate`) or `managed` (Managed KB / SharePoint connector + `Retrieve` & `Converse`).
   - **`SHAREPOINT_PERMISSION_SCOPE` (`config.env`):** When linking a SharePoint Managed KB, choose `Sites.Selected` *(recommended, least privilege — SharePoint Admin grants access per site)* or `Sites.Read.All` *(tenant-wide read — simpler setup, wider blast radius)*.
   - **`single`:** Each question is answered independently (no prior chat history sent; lower token cost).
   - **`multi`:** Loads the last 6 turns for the `session_id` from DynamoDB so you can ask follow-up questions.
   - *(Note: When creating a new Knowledge Base, `./deploy.sh` automatically waits for the BDA ingestion job to reach `COMPLETE` and then runs the post-deploy smoke test.)*
6. In your **host terminal**, export the `RAG_API_URL` and `RAG_API_KEY` printed by `./deploy.sh` and chat:
   ```bash
   cd /home/reg/Coding/AWS_chatbot_experiment
   export RAG_API_URL="https://<api-id>.execute-api.eu-west-1.amazonaws.com/<stage>/chat"
   export RAG_API_KEY="<your-api-key>"
   python3 chat_cli.py
   ```
7. When finished, tear down lab resources from inside the Podman container. You will be asked whether to keep the Knowledge Base (and its S3/vector storage) — type `YES` (in capital letters) to keep it and save `KB_NAME`/`KB_ID` to `config.env` so the next `./deploy.sh` reuses it without re-ingesting PDFs (any other input deletes it):
   ```bash
   ./teardown.sh
   exit
   ```

---

## 3. Running Local Unit & Contract Tests

Run the local test suite anytime (no AWS credentials or extra pip packages required):
```bash
python3 -m unittest discover -s tests -v
```

---

## 4. Option B — Run in AWS CloudShell (`eu-west-1`)

1. Open **AWS CloudShell** in the AWS Console (top-right region set to **`eu-west-1`**).
2. Clone or update the repo:
   ```bash
   git clone https://github.com/revhawk/AWS_Chatbot_experiment.git
   cd AWS_Chatbot_experiment
   ```
3. Upload your PDFs into `app_docs/` (CloudShell **Actions → Upload file**), then run `./deploy.sh`.
4. Copy the printed `export RAG_API_URL=...` and `export RAG_API_KEY=...` into your **local terminal** and run `python3 chat_cli.py`.
5. When done, run `./teardown.sh` in CloudShell.

---

## 5. Option C — Run Locally with AWS CLI v2

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
aws login              # or: aws sso login / aws configure
cd /home/reg/Coding/AWS_chatbot_experiment
./deploy.sh
```

---

## 6. Checking Stages & Logs

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

## 7. Key Fixes Included

- **`bedrock:GetInferenceProfile` in `LambdaRagPolicy` (`scripts/compute_api.sh`):** Required when calling `RetrieveAndGenerate` with an inference profile ARN (`eu.amazon.nova-micro-v1:0`).
- **Dual-mode Lambda (`lambda/handler.py`):** Supports both S3 Vectors Knowledge Bases (`KB_MODE=vector`, default for `deploy.sh` via `retrieve_and_generate`) and Console Managed Knowledge Bases (`KB_MODE=managed` via `retrieve` + `converse`), extracting S3, SharePoint, and Web citation URLs.
- **Podman `aws login --remote`:** Bypasses container `127.0.0.1` callback issues when authenticating from a host browser.
