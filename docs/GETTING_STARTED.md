# Getting Started — Quickstart Guide

Get the serverless Amazon Bedrock RAG chatbot deployed in `eu-west-1` and answering questions over your PDFs in ~5 minutes using **Podman** (no host AWS CLI or Terraform installs required).

---

## Prerequisites

- **Podman** (or Docker) on your machine, plus **Python 3** for `chat_cli.py` and offline tests.
- **AWS Account** with Bedrock model access in **`eu-west-1`** (`amazon.titan-embed-text-v2:0` and `eu.amazon.nova-micro-v1:0`).
- **1–2 short PDF documents** to place in `app_docs/`.

---

## 5-Minute Quickstart (Recommended — Bash + Podman)

### 1. Clone & Add Your PDFs
```bash
git clone https://github.com/revhawk/AWS_Chatbot_experiment.git
cd AWS_Chatbot_experiment
cp /path/to/your-whitepaper.pdf app_docs/
```

*(Optional)* Copy the config template so `./deploy.sh` runs with your defaults:
```bash
cp config.env.example config.env
```

### 2. Start the Tools Container & Sign In to AWS
Build once (includes AWS CLI v2, `zip`, and Terraform):
```bash
podman build -t aws-rag-cli .
```

Start the ephemeral container and authenticate:
```bash
podman run --rm -it \
  -v "$PWD:/work:Z" \
  -v "$HOME/.aws:/root/.aws:Z" \
  -w /work \
  aws-rag-cli

aws login --remote
```

### 3. Deploy & Auto-Verify
Inside the container, run:
```bash
./deploy.sh
```
What happens automatically:
1. Checks for any reusable Knowledge Base, Guardrail, or DynamoDB table from earlier runs.
2. Shows a **Pre-Deploy Check & Build Plan** (`[CREATE]` / `[REUSE]` / `[SKIP]`) and asks you to confirm.
3. Provisions the stack, uploads `app_docs/`, and waits for **Bedrock Data Automation (BDA)** ingestion to finish.
4. Runs **5 live post-deploy checks** (`403` missing API key check, RAG sample query, custom word block, prompt attack block, and PII anonymization).
5. Prints the exact `export RAG_API_URL=...` and `export RAG_API_KEY=...` commands to run next.

### 4. Start Chatting (Host Terminal)
Open a terminal on your host machine, paste the two `export` lines printed by `./deploy.sh`, and launch the CLI:
```bash
cd /path/to/AWS_Chatbot_experiment
export RAG_API_URL="https://<api-id>.execute-api.eu-west-1.amazonaws.com/<stage>/chat"
export RAG_API_KEY="<your-api-key>"
python3 chat_cli.py
```

### 5. Tear Down Cleanly (Save Tokens for Next Time)
When you're done, run teardown inside the Podman container:
```bash
./teardown.sh
```
- **To keep your Knowledge Base** (and skip re-ingestion time & embedding token costs on your next `./deploy.sh`), type **`YES`** (exact capital letters) when prompted — `KB_NAME` and `KB_ID` are saved automatically to `config.env`.
- **To delete everything**, press Enter or type anything else.

---

## Alternative: 2-Stack Terraform Quickstart (IaC)

If you prefer Terraform (`terraform plan` / `apply` / `destroy`) inside the same Podman container:

```bash
# 1. Persistent Knowledge Base & Guardrail stack (deploy once, keep across teardowns)
cd /work/infra/terraform/knowledge
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply

# 2. Ephemeral App stack (DynamoDB, Lambda, API Gateway, Resource Group)
cd /work/infra/terraform/app
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply
```

See [infra/terraform/README.md](../infra/terraform/README.md) for PDF upload, BDA ingestion, and `terraform destroy` steps.

---

## Run Offline Tests Anytime (`$0` AWS Cost)

Before deploying or committing changes, verify everything locally (no AWS credentials needed):
```bash
python3 -m unittest discover -s tests -v
python3 tests/mutation_test.py
```

---

## Next Steps

- [ARCHITECTURE.md](ARCHITECTURE.md) — System diagram, naming/tagging, resource reuse, and future SharePoint notes
- [RUNNING_SCRIPTS.md](RUNNING_SCRIPTS.md) — Detailed Podman, CloudShell, local CLI, stage, and log commands
- [TESTING.md](TESTING.md) — Full breakdown of unit, contract, mutation, and post-deploy smoke tests
- [infra/terraform/README.md](../infra/terraform/README.md) — 2-stack Terraform deployment guide
