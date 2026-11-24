data "aws_caller_identity" "current" {}

locals {
  full_prefix = "${var.prefix}-${var.app_name}-${var.stage}"
  account_id  = data.aws_caller_identity.current.account_id

  pii_entities = [
    "NAME",
    "PHONE",
    "EMAIL",
    "ADDRESS",
    "AGE",
    "USERNAME",
    "PASSWORD",
    "DRIVER_ID",
    "LICENSE_PLATE",
    "VEHICLE_IDENTIFICATION_NUMBER",
    "CREDIT_DEBIT_CARD_CVV",
    "CREDIT_DEBIT_CARD_EXPIRY",
    "CREDIT_DEBIT_CARD_NUMBER",
    "PIN",
    "INTERNATIONAL_BANK_ACCOUNT_NUMBER",
    "SWIFT_CODE",
    "IP_ADDRESS",
    "MAC_ADDRESS",
    "URL",
    "AWS_ACCESS_KEY",
    "AWS_SECRET_KEY",
    "US_PASSPORT_NUMBER",
    "US_SOCIAL_SECURITY_NUMBER",
    "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER",
    "US_BANK_ACCOUNT_NUMBER",
    "US_BANK_ROUTING_NUMBER",
    "CA_HEALTH_NUMBER",
    "CA_SOCIAL_INSURANCE_NUMBER",
    "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER",
    "UK_NATIONAL_INSURANCE_NUMBER",
    "UK_NATIONAL_HEALTH_SERVICE_NUMBER",
  ]
}

# --- 1. S3 Source & Supplemental Buckets (SSE-S3 AES256, $0 KMS key fees) ---

resource "aws_s3_bucket" "source" {
  bucket        = "${local.full_prefix}-docs-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "supplemental" {
  bucket        = "${local.full_prefix}-bda-supp-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "supplemental" {
  bucket = aws_s3_bucket.supplemental.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- 2. Amazon S3 Vectors Bucket & 1024-dim Cosine Index ---

resource "aws_s3vectors_vector_bucket" "vectors" {
  vector_bucket_name = "${local.full_prefix}-vec"
  encryption_configuration {
    sse_type = "AES256"
  }
}

resource "aws_s3vectors_index" "whitepapers" {
  vector_bucket_name = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
  index_name         = "whitepapers-index"
  data_type          = "float32"
  dimension          = 1024
  distance_metric    = "cosine"

  metadata_configuration {
    non_filterable_metadata_keys = [
      "AMAZON_BEDROCK_TEXT",
      "AMAZON_BEDROCK_METADATA",
    ]
  }

  encryption_configuration {
    sse_type = "AES256"
  }
}

# --- 3. IAM Role for Bedrock Knowledge Base + BDA ---

resource "aws_iam_role" "kb" {
  name = "${local.full_prefix}-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${local.account_id}:knowledge-base/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "kb" {
  name = "KBInlinePolicy"
  role = aws_iam_role.kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeDataAutomationAsync", "bedrock:GetDataAutomationStatus"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          aws_s3_bucket.source.arn,
          "${aws_s3_bucket.source.arn}/*",
          aws_s3_bucket.supplemental.arn,
          "${aws_s3_bucket.supplemental.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3vectors:*"]
        Resource = [
          aws_s3vectors_vector_bucket.vectors.vector_bucket_arn,
          aws_s3vectors_index.whitepapers.index_arn,
        ]
      },
    ]
  })
}

# --- 4. Bedrock Knowledge Base & BDA Data Source ---

resource "aws_bedrockagent_knowledge_base" "main" {
  name     = "${local.full_prefix}-kb"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embedding_model_id}"
      supplemental_data_storage_configuration {
        storage_location {
          type = "S3"
          s3_location {
            uri = "s3://${aws_s3_bucket.supplemental.bucket}/"
          }
        }
      }
    }
  }

  storage_configuration {
    type = "S3_VECTORS"
    s3_vectors_configuration {
      vector_bucket_arn = aws_s3vectors_vector_bucket.vectors.vector_bucket_arn
      index_arn         = aws_s3vectors_index.whitepapers.index_arn
    }
  }

  depends_on = [aws_iam_role_policy.kb]
}

resource "aws_bedrockagent_data_source" "whitepapers" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name              = "whitepapers-bda-source"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.source.arn
    }
  }

  vector_ingestion_configuration {
    parsing_configuration {
      parsing_strategy = "BEDROCK_DATA_AUTOMATION"
    }
  }
}

# --- 5. Optional Bedrock Guardrail ---

resource "aws_bedrock_guardrail" "main" {
  count                     = var.create_guardrail ? 1 : 0
  name                      = "${local.full_prefix}-guardrail"
  description               = "Blocks all foul language and anonymizes PII"
  blocked_input_messaging   = "Sorry, the model cannot answer this question, please stop using foul language."
  blocked_outputs_messaging = "Sorry, the model cannot answer this question, please stop using foul language."

  content_policy_config {
    dynamic "filters_config" {
      for_each = ["VIOLENCE", "MISCONDUCT", "HATE", "SEXUAL", "INSULTS"]
      content {
        type            = filters_config.value
        input_strength  = "HIGH"
        output_strength = "HIGH"
      }
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  word_policy_config {
    words_config {
      text = "Poo"
    }
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = local.pii_entities
      content {
        type   = pii_entities_config.value
        action = "ANONYMIZE"
      }
    }
  }
}
