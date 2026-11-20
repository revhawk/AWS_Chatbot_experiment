# AWS Bedrock RAG Chatbot Experiment

Serverless Retrieval-Augmented Generation (RAG) chatbot built on Amazon Bedrock in `eu-west-1` with zero idle compute costs:
- **Amazon Bedrock Knowledge Base** with **Amazon S3 Vectors** (1024-dim cosine index)
- **Bedrock Data Automation (BDA)** for multimodal PDF parsing
- **Amazon Bedrock Guardrails** (`Foul_Language_Blocker-*`) for content, profanity/word, and PII filtering
- **AWS Lambda + API Gateway (REST + API Key)** for serverless inference
- **Amazon DynamoDB (On-Demand)** for session chat history and audit logging

## Usage

1. Place 1–2 short PDF white papers into `app_docs/`.
2. Deploy the stack (prompts for an API Gateway stage and conversation memory mode `single` or `multi`, or pass them directly):
   ```bash
   ./deploy.sh
   # or skip the prompts:
   ./deploy.sh dev multi
   ```
3. Export the `RAG_API_URL` and `RAG_API_KEY` printed at the end of `deploy.sh`, then start chatting:
   ```bash
   python3 chat_cli.py
   ```
4. Tear down all lab resources when finished:
   ```bash
   ./teardown.sh
   ```

## Stages

- **Run in a different stage:** Pass the stage name to `./deploy.sh` (e.g. `./deploy.sh dev` or `./deploy.sh staging`) or enter it when prompted. Note that `./deploy.sh` creates a new timestamped stack each time and overwrites `.env.lab`, so run `./teardown.sh` before deploying another stack—or back up `.env.lab` per stage (e.g. `.env.lab.dev`).
- **Find available stages:**
  - **AWS Console (`eu-west-1`):** Open **API Gateway** → select your API (`bedrock-rag-api-*`) → click **Stages** in the left sidebar.
  - **AWS CLI:**
    ```bash
    source .env.lab
    aws apigateway get-stages --rest-api-id "${API_ID}" --region "${AWS_REGION}" --query 'item[].stageName' --output table
    ```
  - **Check your current `.env.lab` stage:**
    ```bash
    grep STAGE .env.lab
    ```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architectural decisions and system diagram
- [docs/RUNNING_SCRIPTS.md](docs/RUNNING_SCRIPTS.md) — Podman, CloudShell, and local deployment instructions

## License

Licensed under the [MIT License](LICENSE).
