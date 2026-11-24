variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Lowercase prefix for all resource names"
  type        = string
  default     = "lab"
}

variable "app_name" {
  description = "Lowercase project name for all resources"
  type        = string
  default     = "bedrock-rag"
}

variable "stage" {
  description = "API Gateway stage and resource tag (e.g. dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "cost_centre" {
  description = "Tag value for CostCentre"
  type        = string
  default     = "IT"
}

variable "resource_id" {
  description = "Tag value for ResourceID"
  type        = string
  default     = "001"
}

variable "kb_mode" {
  description = "Knowledge Base query mode: 'vector' (S3 Vectors + RetrieveAndGenerate) or 'managed' (Managed/SharePoint KB + Retrieve/Converse)"
  type        = string
  default     = "vector"

  validation {
    condition     = contains(["vector", "managed"], var.kb_mode)
    error_message = "kb_mode must be 'vector' or 'managed'."
  }
}

variable "memory_mode" {
  description = "Conversation memory mode: 'single' (stateless) or 'multi' (loads recent turns from DynamoDB)"
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "multi"], var.memory_mode)
    error_message = "memory_mode must be 'single' or 'multi'."
  }
}

variable "model_id" {
  description = "Bedrock inference profile ID for answer generation"
  type        = string
  default     = "eu.amazon.nova-micro-v1:0"
}

variable "kb_id" {
  description = "Optional explicit Knowledge Base ID (leave blank to read automatically from ../knowledge/terraform.tfstate)"
  type        = string
  default     = ""
}

variable "guardrail_id" {
  description = "Optional explicit Guardrail ID (leave blank to read automatically from ../knowledge/terraform.tfstate)"
  type        = string
  default     = ""
}

variable "guardrail_version" {
  description = "Optional Guardrail version (leave blank to read from ../knowledge/terraform.tfstate or default to DRAFT)"
  type        = string
  default     = ""
}

variable "use_knowledge_remote_state" {
  description = "Read kb_id and guardrail_id from ../knowledge/terraform.tfstate when not explicitly provided"
  type        = bool
  default     = true
}

variable "sharepoint_permission_scope" {
  description = "Entra ID permission scope when using a SharePoint Managed KB: 'Sites.Selected' (recommended, least privilege) or 'Sites.Read.All' (tenant-wide)"
  type        = string
  default     = "Sites.Selected"

  validation {
    condition     = contains(["Sites.Selected", "Sites.Read.All"], var.sharepoint_permission_scope)
    error_message = "sharepoint_permission_scope must be 'Sites.Selected' or 'Sites.Read.All'."
  }
}
