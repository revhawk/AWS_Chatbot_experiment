output "kb_id" {
  description = "Bedrock Knowledge Base ID"
  value       = aws_bedrockagent_knowledge_base.main.id
}

output "kb_name" {
  description = "Bedrock Knowledge Base name"
  value       = aws_bedrockagent_knowledge_base.main.name
}

output "data_source_id" {
  description = "Bedrock Knowledge Base S3/BDA Data Source ID"
  value       = aws_bedrockagent_data_source.whitepapers.data_source_id
}

output "source_bucket" {
  description = "S3 source documents bucket"
  value       = aws_s3_bucket.source.bucket
}

output "supp_bucket" {
  description = "S3 BDA supplemental storage bucket"
  value       = aws_s3_bucket.supplemental.bucket
}

output "vector_bucket" {
  description = "S3 Vectors bucket name"
  value       = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
}

output "guardrail_id" {
  description = "Bedrock Guardrail ID (created or pre-existing)"
  value       = var.create_guardrail ? aws_bedrock_guardrail.main[0].guardrail_id : var.existing_guardrail_id
}

output "guardrail_version" {
  description = "Bedrock Guardrail version"
  value       = var.guardrail_version
}
