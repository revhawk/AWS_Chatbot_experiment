# Module: Optional SharePoint Online Connector with X.509 Certificate Auth & ACL Preservation
#
# How SharePoint ACL preservation works:
#   1. Register an Entra ID App with least-privilege SharePoint API permission (Sites.Selected).
#   2. Upload the public X.509 certificate (.crt) to the Entra ID App Registration.
#   3. Store the X.509 certificate + private key + tenantId/clientId in the KMS-encrypted
#      AWS Secrets Manager secret created below (via scripts/mock_sharepoint_x509.sh --upload-secret).
#   4. Amazon Bedrock Knowledge Bases authenticates app-only using the X.509 credentials,
#      crawls approved SharePoint sites, and preserves document ACLs (user/group permissions)
#      for security-trimmed RAG retrieval at query time.

variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "knowledge_base_id" {
  type = string
}

variable "kb_role_name" {
  type = string
}

variable "sharepoint_domain" {
  description = "SharePoint Online domain prefix (e.g. 'contoso' for contoso.sharepoint.com)"
  type        = string
}

variable "sharepoint_tenant_id" {
  description = "Microsoft Entra ID Tenant GUID"
  type        = string
}

variable "sharepoint_site_urls" {
  description = "Approved SharePoint Online site URLs scoped via Sites.Selected"
  type        = list(string)
}

variable "sharepoint_auth_type" {
  description = "Bedrock SharePoint connector auth type for X.509 app-only ACL crawling"
  type        = string
  default     = "OAUTH2_SHAREPOINT_APP_ONLY_CLIENT_CREDENTIALS"
}

# --- KMS-Encrypted Secrets Manager Secret for X.509 Certificate & Private Key ---

resource "aws_secretsmanager_secret" "sharepoint_x509" {
  name                    = "${var.name_prefix}/sharepoint-x509-connector"
  description             = "X.509 certificate and private key for SharePoint Online app-only ACL-preserving connector"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

# Least-privilege IAM policy allowing ONLY the Bedrock KB role to read this secret
resource "aws_iam_role_policy" "kb_sharepoint_secret" {
  name = "KBSharePointX509SecretAccess"
  role = var.kb_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSharePointX509Secret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.sharepoint_x509.arn
      },
      {
        Sid      = "DecryptSharePointX509Secret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# --- Bedrock Knowledge Base SharePoint Online Data Source (App-Only X.509 + ACLs) ---

resource "aws_bedrockagent_data_source" "sharepoint" {
  knowledge_base_id = var.knowledge_base_id
  name              = "sharepoint-x509-acl-source"

  data_source_configuration {
    type = "SHAREPOINT"
    share_point_configuration {
      source_configuration {
        auth_type              = var.sharepoint_auth_type
        credentials_secret_arn = aws_secretsmanager_secret.sharepoint_x509.arn
        domain                 = var.sharepoint_domain
        host_type              = "ONLINE"
        site_urls              = var.sharepoint_site_urls
        tenant_id              = var.sharepoint_tenant_id
      }
    }
  }

  depends_on = [aws_iam_role_policy.kb_sharepoint_secret]
}

output "sharepoint_secret_arn" {
  value = aws_secretsmanager_secret.sharepoint_x509.arn
}

output "sharepoint_data_source_id" {
  value = aws_bedrockagent_data_source.sharepoint.data_source_id
}
