# Root Stack 1 (Persistent): KMS CMK + 2-AZ Private VPC & Endpoints + Knowledge Base/Guardrail + Observability

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Name       = "${var.prefix}-${var.app_name}"
      Project    = var.app_name
      Stage      = var.stage
      CostCentre = var.cost_centre
      ResourceID = var.resource_id
      ManagedBy  = "Terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "prefix" {
  type    = string
  default = "lab"
}

variable "app_name" {
  type    = string
  default = "bedrock-rag"
}

variable "stage" {
  type    = string
  default = "prod"
}

variable "cost_centre" {
  type    = string
  default = "IT"
}

variable "resource_id" {
  type    = string
  default = "001"
}

variable "access_allowed_cidrs" {
  description = "Zscaler (or Mock Zscaler bastion/VPN) CIDR blocks permitted to reach Internal ALB on TCP 443"
  type        = list(string)
  default     = ["10.40.0.0/16"]
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.prefix}-${var.app_name}-${var.stage}"
  account_id  = data.aws_caller_identity.current.account_id
}

module "kms" {
  source      = "../../modules/kms"
  name_prefix = local.name_prefix
  account_id  = local.account_id
  aws_region  = var.aws_region
}

module "vpc_endpoints" {
  source               = "../../modules/vpc_endpoints"
  name_prefix          = local.name_prefix
  aws_region           = var.aws_region
  account_id           = local.account_id
  access_allowed_cidrs = var.access_allowed_cidrs
  kms_key_arn          = module.kms.kms_key_arn
}

module "knowledge_base" {
  source      = "../../modules/knowledge_base"
  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  account_id  = local.account_id
  kms_key_arn = module.kms.kms_key_arn
}

module "observability" {
  source      = "../../modules/observability"
  name_prefix = local.name_prefix
  account_id  = local.account_id
  kms_key_arn = module.kms.kms_key_arn
}

output "kms_key_arn" { value = module.kms.kms_key_arn }
output "vpc_id" { value = module.vpc_endpoints.vpc_id }
output "private_subnet_ids" { value = module.vpc_endpoints.private_subnet_ids }
output "sg_alb_id" { value = module.vpc_endpoints.sg_alb_id }
output "sg_lambda_id" { value = module.vpc_endpoints.sg_lambda_id }
output "sg_runtime_id" { value = module.vpc_endpoints.sg_runtime_id }
output "execute_api_vpce_id" { value = module.vpc_endpoints.execute_api_vpce_id }
output "execute_api_vpce_eni_ids" { value = module.vpc_endpoints.execute_api_vpce_eni_ids }
output "s3_interface_vpce_id" { value = module.vpc_endpoints.s3_interface_vpce_id }
output "s3_interface_vpce_eni_ids" { value = module.vpc_endpoints.s3_interface_vpce_eni_ids }
output "kb_id" { value = module.knowledge_base.kb_id }
output "data_source_id" { value = module.knowledge_base.data_source_id }
output "source_bucket" { value = module.knowledge_base.source_bucket }
output "guardrail_id" { value = module.knowledge_base.guardrail_id }
output "guardrail_version" { value = module.knowledge_base.guardrail_version }
output "audit_logs_bucket" { value = module.observability.audit_logs_bucket }
