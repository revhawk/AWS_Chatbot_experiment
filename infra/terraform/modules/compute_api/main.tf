# Module: Private REST API Gateway (VPCE-only) + VPC-attached Lambda + KMS DynamoDB (PITR) + Resource Group (C1, C2, C5, C11, C12)

variable "name_prefix" {
  type = string
}

variable "app_name" {
  type = string
}

variable "stage" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "sg_lambda_id" {
  type = string
}

variable "execute_api_vpce_id" {
  type = string
}

variable "agentcore_runtime_arn" {
  type = string
}

variable "entra_issuer" {
  type = string
}

variable "entra_audience" {
  type = string
}

variable "entra_jwks_url" {
  type = string
}

variable "backend_source_dir" {
  type = string
}

# --- DynamoDB Table (On-Demand, KMS CMK, Point-in-Time Recovery) ---

resource "aws_dynamodb_table" "history" {
  name         = "${var.name_prefix}-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "timestamp"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# --- VPC-Attached Lambda Execution Role & Function ---

data "archive_file" "backend_zip" {
  type        = "zip"
  source_dir  = var.backend_source_dir
  output_path = "${path.module}/.build/backend.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_exec" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_least_privilege" {
  name = "LambdaPrivateRagPolicy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = var.agentcore_runtime_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.history.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-chat"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "chat" {
  function_name    = "${var.name_prefix}-chat"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  handler          = "entrypoints.lambda_handler.lambda_handler"
  filename         = data.archive_file.backend_zip.output_path
  source_code_hash = data.archive_file.backend_zip.output_base64sha256
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = var.kms_key_arn

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_lambda_id]
  }

  environment {
    variables = {
      AGENTCORE_RUNTIME_ARN = var.agentcore_runtime_arn
      TABLE_NAME            = aws_dynamodb_table.history.name
      ENTRA_ISSUER          = var.entra_issuer
      ENTRA_AUDIENCE        = var.entra_audience
      ENTRA_JWKS_URL        = var.entra_jwks_url
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_vpc_exec,
    aws_iam_role_policy.lambda_least_privilege,
  ]
}

# --- Private REST API Gateway (Restricted Strictly to execute-api VPCE) ---

resource "aws_api_gateway_rest_api" "private" {
  name = "${var.name_prefix}-private-api"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [var.execute_api_vpce_id]
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "execute-api:/*"
        Condition = { StringNotEquals = { "aws:SourceVpce" = var.execute_api_vpce_id } }
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "execute-api:Invoke"
        Resource  = "execute-api:/*"
        Condition = { StringEquals = { "aws:SourceVpce" = var.execute_api_vpce_id } }
      },
    ]
  })
}

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.private.id
  parent_id   = aws_api_gateway_rest_api.private.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.private.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "chat"
}

resource "aws_api_gateway_resource" "feedback" {
  rest_api_id = aws_api_gateway_rest_api.private.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "feedback"
}

resource "aws_api_gateway_method" "post_chat" {
  rest_api_id   = aws_api_gateway_rest_api.private.id
  resource_id   = aws_api_gateway_resource.chat.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "post_feedback" {
  rest_api_id   = aws_api_gateway_rest_api.private.id
  resource_id   = aws_api_gateway_resource.feedback.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "chat" {
  rest_api_id             = aws_api_gateway_rest_api.private.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = aws_api_gateway_method.post_chat.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.chat.invoke_arn
}

resource "aws_api_gateway_integration" "feedback" {
  rest_api_id             = aws_api_gateway_rest_api.private.id
  resource_id             = aws_api_gateway_resource.feedback.id
  http_method             = aws_api_gateway_method.post_feedback.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.chat.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "private-apigw-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.private.execution_arn}/*/*/api/*"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.private.id
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.chat.id,
      aws_api_gateway_integration.feedback.id,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.private.id
  stage_name    = var.stage
}

# --- AWS Resource Group (Groups Both Persistent & App Stacks) ---

resource "aws_resourcegroups_group" "stack" {
  name        = "${var.name_prefix}-rg"
  description = "TDA-aligned AWS Bedrock RAG Assistant (${var.name_prefix})"

  resource_query {
    type = "TAG_FILTERS_1_0"
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        { Key = "Project", Values = [var.app_name] },
        { Key = "Stage", Values = [var.stage] },
      ]
    })
  }
}

output "private_api_id" {
  value = aws_api_gateway_rest_api.private.id
}

output "lambda_name" {
  value = aws_lambda_function.chat.function_name
}

output "ddb_table" {
  value = aws_dynamodb_table.history.name
}

output "resource_group_name" {
  value = aws_resourcegroups_group.stack.name
}
