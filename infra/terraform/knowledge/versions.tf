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
