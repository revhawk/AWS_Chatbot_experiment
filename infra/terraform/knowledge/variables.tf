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
  description = "Deployment stage tag (e.g. dev, staging, prod)"
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

variable "embedding_model_id" {
  description = "Bedrock embedding foundation model ID"
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "create_guardrail" {
  description = "Set to false to reuse an existing Bedrock Guardrail via existing_guardrail_id"
  type        = bool
  default     = true
}

variable "existing_guardrail_id" {
  description = "Existing Bedrock Guardrail ID to reuse when create_guardrail = false (e.g. xojv3g7paumh)"
  type        = string
  default     = ""
}

variable "guardrail_version" {
  description = "Bedrock Guardrail version to use"
  type        = string
  default     = "DRAFT"
}
