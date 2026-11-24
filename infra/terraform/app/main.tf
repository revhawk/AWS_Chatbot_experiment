data "aws_caller_identity" "current" {}

data "terraform_remote_state" "knowledge" {
  count   = var.use_knowledge_remote_state ? 1 : 0
  backend = "local"

  config = {
    path = "${path.module}/../knowledge/terraform.tfstate"
  }
}

locals {
  full_prefix = "${var.prefix}-${var.app_name}-${var.stage}"
  account_id  = data.aws_caller_identity.current.account_id

  kb_id = var.kb_id != "" ? var.kb_id : (
    var.use_knowledge_remote_state ? data.terraform_remote_state.knowledge[0].outputs.kb_id : ""
  )
  guardrail_id = var.guardrail_id != "" ? var.guardrail_id : (
    var.use_knowledge_remote_state ? data.terraform_remote_state.knowledge[0].outputs.guardrail_id : ""
  )
  guardrail_version = var.guardrail_version != "" ? var.guardrail_version : (
    var.use_knowledge_remote_state ? data.terraform_remote_state.knowledge[0].outputs.guardrail_version : "DRAFT"
  )
}

# --- 1. DynamoDB Chat History & Audit Table (On-Demand, AWS Owned Key) ---

resource "aws_dynamodb_table" "history" {
  name         = "${local.full_prefix}-history"
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
}

# --- 2. Lambda Execution Role & Function ---

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/handler.py"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.full_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_rag" {
  name = "LambdaRagPolicy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:RetrieveAndGenerate",
          "bedrock:Retrieve",
          "bedrock:InvokeModel",
          "bedrock:GetInferenceProfile",
          "bedrock:ApplyGuardrail",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.history.arn
      },
    ]
  })
}

resource "aws_lambda_function" "chat" {
  function_name    = "${local.full_prefix}-chat"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      KB_ID             = local.kb_id
      KB_MODE           = var.kb_mode
      MODEL_ARN         = "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${var.model_id}"
      GUARDRAIL_ID      = local.guardrail_id
      GUARDRAIL_VERSION = local.guardrail_version
      TABLE_NAME        = aws_dynamodb_table.history.name
      MEMORY_MODE       = var.memory_mode
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_rag,
  ]
}

# --- 3. API Gateway REST API (POST /chat + x-api-key + Usage Plan) ---

resource "aws_api_gateway_rest_api" "chat" {
  name = "${local.full_prefix}-api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.chat.id
  parent_id   = aws_api_gateway_rest_api.chat.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "post_chat" {
  rest_api_id      = aws_api_gateway_rest_api.chat.id
  resource_id      = aws_api_gateway_resource.chat.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.chat.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = aws_api_gateway_method.post_chat.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.chat.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "apigw-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.chat.execution_arn}/*/POST/chat"
}

resource "aws_api_gateway_deployment" "chat" {
  rest_api_id = aws_api_gateway_rest_api.chat.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.chat.id,
      aws_api_gateway_method.post_chat.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.lambda]
}

resource "aws_api_gateway_stage" "chat" {
  deployment_id = aws_api_gateway_deployment.chat.id
  rest_api_id   = aws_api_gateway_rest_api.chat.id
  stage_name    = var.stage
}

resource "aws_api_gateway_api_key" "chat" {
  name    = "${local.full_prefix}-api-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "chat" {
  name = "${local.full_prefix}-api-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.chat.id
    stage  = aws_api_gateway_stage.chat.stage_name
  }

  throttle_settings {
    rate_limit  = 5
    burst_limit = 10
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "chat" {
  key_id        = aws_api_gateway_api_key.chat.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.chat.id
}

# --- 4. AWS Resource Group (Groups BOTH Persistent Knowledge & Ephemeral App Stacks) ---

resource "aws_resourcegroups_group" "stack" {
  name        = "${local.full_prefix}-rg"
  description = "AWS Bedrock RAG Chatbot (${var.prefix}-${var.app_name}, stage=${var.stage})"

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
