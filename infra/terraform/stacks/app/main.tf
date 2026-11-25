# Root Stack 2 (Ephemeral App): SPA Hosting + Private API/VPC Lambda/KMS DynamoDB + Internal ALB/WAF

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
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

variable "acm_certificate_arn" {
  description = "ACM TLS certificate ARN for the Internal ALB HTTPS/443 listener"
  type        = string
}

variable "agentcore_runtime_arn" {
  description = "Bedrock AgentCore Runtime ARN (VPC mode) invoked by Lambda via AgentCore Interface VPCE"
  type        = string
}

variable "entra_issuer" {
  description = "Entra ID (or Mock OIDC) JWT issuer URL"
  type        = string
  default     = "https://mock-entra.local/v2.0"
}

variable "entra_audience" {
  description = "Entra ID (or Mock OIDC) expected JWT audience"
  type        = string
  default     = "api://bedrock-rag-assistant"
}

variable "entra_jwks_url" {
  description = "Entra ID (or Mock OIDC) JWKS URL for RS256 signature verification"
  type        = string
  default     = "https://mock-entra.local/discovery/v2.0/keys"
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "persistent" {
  backend = "local"
  config = {
    path = "${path.module}/../persistent/terraform.tfstate"
  }
}

locals {
  name_prefix = "${var.prefix}-${var.app_name}-${var.stage}"
  account_id  = data.aws_caller_identity.current.account_id
  p           = data.terraform_remote_state.persistent.outputs
}

module "spa_hosting" {
  source               = "../../modules/spa_hosting"
  name_prefix          = local.name_prefix
  account_id           = local.account_id
  kms_key_arn          = local.p.kms_key_arn
  s3_interface_vpce_id = local.p.s3_interface_vpce_id
}

module "compute_api" {
  source                = "../../modules/compute_api"
  name_prefix           = local.name_prefix
  app_name              = var.app_name
  stage                 = var.stage
  aws_region            = var.aws_region
  account_id            = local.account_id
  kms_key_arn           = local.p.kms_key_arn
  private_subnet_ids    = local.p.private_subnet_ids
  sg_lambda_id          = local.p.sg_lambda_id
  execute_api_vpce_id   = local.p.execute_api_vpce_id
  agentcore_runtime_arn = var.agentcore_runtime_arn
  entra_issuer          = var.entra_issuer
  entra_audience        = var.entra_audience
  entra_jwks_url        = var.entra_jwks_url
  backend_source_dir    = "${path.module}/../../../../backend"
}

module "edge_ingress" {
  source                    = "../../modules/edge_ingress"
  name_prefix               = local.name_prefix
  vpc_id                    = local.p.vpc_id
  private_subnet_ids        = local.p.private_subnet_ids
  sg_alb_id                 = local.p.sg_alb_id
  acm_certificate_arn       = var.acm_certificate_arn
  execute_api_vpce_eni_ids  = local.p.execute_api_vpce_eni_ids
  s3_interface_vpce_eni_ids = local.p.s3_interface_vpce_eni_ids
  access_logs_bucket        = local.p.audit_logs_bucket
}

output "alb_dns_name" { value = module.edge_ingress.alb_dns_name }
output "waf_web_acl_arn" { value = module.edge_ingress.waf_web_acl_arn }
output "spa_bucket_name" { value = module.spa_hosting.spa_bucket_name }
output "private_api_id" { value = module.compute_api.private_api_id }
output "lambda_name" { value = module.compute_api.lambda_name }
output "ddb_table" { value = module.compute_api.ddb_table }
output "resource_group_name" { value = module.compute_api.resource_group_name }
