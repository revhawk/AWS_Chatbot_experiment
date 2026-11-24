output "api_url" {
  description = "API Gateway POST /chat endpoint URL"
  value       = "${aws_api_gateway_stage.chat.invoke_url}/chat"
}

output "api_key" {
  description = "API Gateway x-api-key value"
  value       = aws_api_gateway_api_key.chat.value
  sensitive   = true
}

output "lambda_name" {
  description = "Deployed Lambda function name"
  value       = aws_lambda_function.chat.function_name
}

output "ddb_table" {
  description = "DynamoDB chat history table name"
  value       = aws_dynamodb_table.history.name
}

output "resource_group_name" {
  description = "AWS Resource Group grouping both knowledge and app stacks"
  value       = aws_resourcegroups_group.stack.name
}

output "kb_id" {
  description = "Linked Bedrock Knowledge Base ID"
  value       = local.kb_id
}

output "guardrail_id" {
  description = "Linked Bedrock Guardrail ID"
  value       = local.guardrail_id
}
