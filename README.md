# AWS Bedrock RAG Chatbot Experiment

Serverless Retrieval-Augmented Generation (RAG) chatbot built on Amazon Bedrock in `eu-west-1` with zero idle compute costs:
- **Amazon Bedrock Knowledge Base** with **Amazon S3 Vectors** (1024-dim cosine index)
- **Bedrock Data Automation (BDA)** for multimodal PDF parsing
- **Amazon Bedrock Guardrails** (`xojv3g7paumh`) for input/output filtering
- **AWS Lambda + API Gateway (REST + API Key)** for serverless inference
- **Amazon DynamoDB (On-Demand)** for session chat history and audit logging

## Usage

1. Place 1–2 short PDF white papers into `docs/`.
2. Deploy the stack:
   ```bash
   ./deploy.sh
   ```
3. Export the `RAG_API_URL` and `RAG_API_KEY` printed at the end of `deploy.sh`, then start chatting:
   ```bash
   python3 chat_cli.py
   ```
4. Tear down all lab resources when finished (preserves your existing Guardrail):
   ```bash
   ./teardown.sh
   ```
