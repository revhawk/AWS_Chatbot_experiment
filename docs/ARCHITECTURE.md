# Project Context & Architectural Decisions

## Goal
Serverless RAG chatbot over AI white paper PDFs in AWS `eu-west-1` with $0 idle compute cost and a clean teardown script.

## Locked-In Design Choices
- **Region:** `eu-west-1` (Ireland)
- **Encryption:** AWS Owned / AWS Managed Keys (`AES256`) only — no Customer Managed KMS keys ($0 key fees).
- **Vector Store & Source Storage:** Amazon S3 Vectors (1024 dimensions, cosine metric, float32) + standard S3 source & supplemental buckets.
- **Document Parsing:** Bedrock Data Automation (`BEDROCK_DATA_AUTOMATION`) enabled on the Knowledge Base data source.
- **Guardrail:** `deploy.sh` creates a Bedrock Guardrail (`Foul_Language_Blocker-*`, version `DRAFT`) with `HIGH` content filters, `PROFANITY` + custom word blocking, and 31 PII anonymizers, enforced via `retrieve_and_generate` / `converse`.
- **Orchestration & State:** Direct `bedrock-agent-runtime.retrieve_and_generate` (for `KB_MODE=vector`) or `retrieve` + `converse` (for `KB_MODE=managed`) inside Python 3.12 AWS Lambda (`bedrock-rag-chat-*`), logging session turns and source URIs to an On-Demand DynamoDB table (`BedrockChatHistory-*`). Supports `MEMORY_MODE=single` (default, stateless) or `MEMORY_MODE=multi` (loads recent session turns from DynamoDB for follow-up questions).
- **API & Auth:** Public regional API Gateway REST API (`POST /chat`) secured with an API key (`x-api-key`) and usage plan throttling (no VPC, ALB, or WAF).
- **Resource Grouping:** All deployed resources are tagged (`Project=AWSBedrockRAGLab`, `Stage`, `Stack`) and grouped under an AWS Resource Group (`bedrock-rag-lab-<stage>-<suffix>`) for single-pane inspection and cleanup verification.
- **Client:** Local CLI script (`chat_cli.py`) using Python stdlib (`urllib.request`).

## Architecture Diagram

```mermaid
flowchart LR
    CLI["chat_cli.py<br/>(Local Terminal)"] -->|"POST /chat + x-api-key"| APIGW["API Gateway REST<br/>(Stage: dev / staging / prod)"]
    APIGW -->|"Lambda Proxy"| LAMBDA["AWS Lambda<br/>(Python 3.12 / 3.15)"]

    LAMBDA -->|"KB_MODE=vector<br/>RetrieveAndGenerate"| KB["Bedrock Knowledge Base<br/>(Titan Embed v2 + BDA)"]
    LAMBDA -->|"KB_MODE=managed<br/>Retrieve + Converse"| KB

    KB <-->|"1024-dim Cosine"| VEC["Amazon S3 Vectors<br/>(AES256)"]
    KB <-->|"Source PDFs & BDA Output"| S3["Amazon S3 Buckets<br/>(SSE-S3 AES256)"]
    KB -->|"Input / Output Filter"| GR["Bedrock Guardrail<br/>(xojv3g7paumh / DRAFT)"]
    LAMBDA -->|"Converse Guardrail"| GR
    LAMBDA -->|"PutItem Audit Log"| DDB["Amazon DynamoDB<br/>(BedrockChatHistory, On-Demand)"]
```

## Repo Files
- `config.env.example` — Template for non-interactive `config.env` deployments (copy to `config.env`, gitignored).
- `deploy.sh` — Modular deployment entrypoint (writes state to gitignored `.env.lab`).
- `teardown.sh` — Modular teardown entrypoint deleting all deployed resources in reverse dependency order.
- `scripts/` — Composable infrastructure modules (`lib/common.sh`, `guardrail.sh`, `storage.sh`, `knowledge_base.sh`, `compute_api.sh`, `resource_group.sh`).
- `lambda/handler.py` — Lambda handler calling `retrieve_and_generate` and writing audit logs to DynamoDB.
- `chat_cli.py` — Interactive CLI chat client.
