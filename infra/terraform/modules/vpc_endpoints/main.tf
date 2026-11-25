# Module: TDA-aligned 2-AZ Private Isolated VPC + Security Groups + Gateway & Interface VPCEs (Controls C2, C5, C10)
# Zero Internet Gateway and zero NAT Gateway: application subnets have no route to the public internet.

variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.1.0/24", "10.40.2.0/24"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b"]
}

variable "access_allowed_cidrs" {
  description = "Zscaler (or Mock Zscaler bastion/VPN) CIDRs permitted to reach Internal ALB on TCP 443"
  type        = list(string)
}

variable "kms_key_arn" {
  type = string
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security Groups matching TDA Network Architecture ---

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-sg-alb"
  description = "Internal ALB: 443 in from Zscaler/Access CIDRs only, 443 out to VPC endpoints"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-sg-endpoints"
  description = "Interface VPC Endpoints: 443 in from sg-alb, sg-lambda, and sg-runtime only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-sg-lambda"
  description = "VPC-attached Lambda: egress 443 to endpoints and DynamoDB/S3 gateway prefix lists only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "runtime" {
  name        = "${var.name_prefix}-sg-runtime"
  description = "AgentCore Runtime (VPC mode): egress 443 to Bedrock endpoints only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_access" {
  for_each          = toset(var.access_allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from Zscaler / Access layer"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_endpoints" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_alb" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_lambda" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.lambda.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_runtime" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.runtime.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_endpoints" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "runtime_to_endpoints" {
  security_group_id            = aws_security_group.runtime.id
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# --- Gateway VPC Endpoints (DynamoDB & S3) ---

locals {
  same_account_vpce_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringEquals = { "aws:PrincipalAccount" = var.account_id }
      }
    }]
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = local.same_account_vpce_policy
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = local.same_account_vpce_policy
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_ddb_gw" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.dynamodb.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3_gw" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.s3_gateway.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- Interface VPC Endpoints (S3 SPA, execute-api, Bedrock Runtime, Bedrock Agent Runtime, AgentCore) ---

resource "aws_vpc_endpoint" "s3_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = false
  policy              = local.same_account_vpce_policy
}

resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = local.same_account_vpce_policy
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = local.same_account_vpce_policy
}

resource "aws_vpc_endpoint" "bedrock_agent_runtime" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-agent-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = local.same_account_vpce_policy
}

resource "aws_vpc_endpoint" "bedrock_agentcore" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-agentcore"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = local.same_account_vpce_policy
}

# --- VPC Flow Logs -> KMS-Encrypted CloudWatch Logs (Control C10) ---

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}-flow-logs"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "VpcFlowLogsPolicy"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "sg_alb_id" {
  value = aws_security_group.alb.id
}

output "sg_endpoints_id" {
  value = aws_security_group.endpoints.id
}

output "sg_lambda_id" {
  value = aws_security_group.lambda.id
}

output "sg_runtime_id" {
  value = aws_security_group.runtime.id
}

output "execute_api_vpce_id" {
  value = aws_vpc_endpoint.execute_api.id
}

output "execute_api_vpce_eni_ids" {
  value = tolist(aws_vpc_endpoint.execute_api.network_interface_ids)
}

output "s3_interface_vpce_id" {
  value = aws_vpc_endpoint.s3_interface.id
}

output "s3_interface_vpce_eni_ids" {
  value = tolist(aws_vpc_endpoint.s3_interface.network_interface_ids)
}
