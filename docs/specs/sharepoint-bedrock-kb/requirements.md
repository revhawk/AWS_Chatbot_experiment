# Requirements: SharePoint → Amazon Bedrock Knowledge Base

## Context
This specification defines the requirements for connecting Microsoft SharePoint Online document libraries as a data source for Amazon Bedrock Knowledge Bases in `eu-west-1`, complementing or replacing the current S3 + S3 Vectors ingestion path.

---

## Functional Requirements (EARS Format)

### 1. Entra ID Authentication & Secrets
1. **Ubiquitous:** The system shall authenticate to Microsoft SharePoint Online using Microsoft Entra ID App-Only OAuth 2.0 (client certificate or client secret stored in AWS Secrets Manager; legacy Azure ACS is retired April 2026).
2. **Ubiquitous:** The system shall encrypt the Entra ID credentials secret in AWS Secrets Manager using a Customer Managed KMS key (`kms` module) in `eu-west-1`.
3. **Unwanted behavior:** If the Entra ID secret is missing, expired, or rotated without updating Secrets Manager, then the ingestion job shall fail with an explicit error logged to CloudWatch without exposing secret values in logs (`redacting_logger.py`).

### 2. Permission Scope & Least Privilege
4. **State-driven:** While `SHAREPOINT_PERMISSION_SCOPE` is set to `Sites.Selected` (recommended default), the Entra ID App Registration shall only access SharePoint sites explicitly granted by a SharePoint Administrator via Graph API / PowerShell.
5. **State-driven:** While `SHAREPOINT_PERMISSION_SCOPE` is set to `Sites.Read.All`, the connector may read all SharePoint sites in the tenant (acceptable only for isolated sandbox tenants).

### 3. Data Source & Ingestion
6. **Event-driven:** When a SharePoint data source is provisioned on the Bedrock Knowledge Base, the system shall configure the SharePoint site URL(s), tenant ID, and Secrets Manager ARN on the Bedrock `SHAREPOINT` data source.
7. **Event-driven:** When a sync is triggered (`start-ingestion-job`), the Knowledge Base shall ingest supported SharePoint documents and extract citations containing the SharePoint web URL (`sharePointLocation.url`).
8. **Ubiquitous:** The backend citation extractor (`lambda/handler.py` and `backend/adapters/ai/agentcore_gateway.py`) shall normalize SharePoint URLs alongside S3 URIs and Web URLs.

### 4. Security & Access Control (ACLs)
9. **Ubiquitous:** The TDA backend shall authenticate callers via Microsoft Entra ID OIDC PKCE Bearer JWT (`jwks_verifier.py`, Control C1) rather than shared API keys when serving SharePoint-backed knowledge.
10. **If/Then:** If document-level SharePoint ACLs are required at retrieval time, then the system shall pass verified caller identity claims from the JWT verifier to the retrieval filter rather than trusting client-supplied `user_id` fields.

### 5. Lifecycle & Teardown
11. **Event-driven:** When `./teardown.sh` or `terraform destroy` runs, the system shall delete the SharePoint data source and Secrets Manager secret (or schedule deletion) cleanly without leaving orphaned IAM permissions.
