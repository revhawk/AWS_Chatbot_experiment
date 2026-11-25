# Module: KMS-encrypted Knowledge S3 + GuardDuty S3 Malware Protection (C9) + S3 Vectors + KB/BDA + Versioned Guardrail (C4, C7)

variable "name_prefix" {
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

variable "embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

locals {
  pii_entities = [
    "NAME", "PHONE", "EMAIL", "ADDRESS", "AGE", "USERNAME", "PASSWORD", "DRIVER_ID",
    "LICENSE_PLATE", "VEHICLE_IDENTIFICATION_NUMBER", "CREDIT_DEBIT_CARD_CVV",
    "CREDIT_DEBIT_CARD_EXPIRY", "CREDIT_DEBIT_CARD_NUMBER", "PIN",
    "INTERNATIONAL_BANK_ACCOUNT_NUMBER", "SWIFT_CODE", "IP_ADDRESS", "MAC_ADDRESS",
    "URL", "AWS_ACCESS_KEY", "AWS_SECRET_KEY", "US_PASSPORT_NUMBER",
    "US_SOCIAL_SECURITY_NUMBER", "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER",
    "US_BANK_ACCOUNT_NUMBER", "US_BANK_ROUTING_NUMBER", "CA_HEALTH_NUMBER",
    "CA_SOCIAL_INSURANCE_NUMBER", "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER",
    "UK_NATIONAL_INSURANCE_NUMBER", "UK_NATIONAL_HEALTH_SERVICE_NUMBER",
  ]
}

# --- S3 Source & Supplemental Buckets (KMS CMK + Block Public Access + TLS-Only) ---

resource "aws_s3_bucket" "source" {
  bucket        = "${var.name_prefix}-docs-${var.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_policy" "source_tls" {
  bucket = aws_s3_bucket.source.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket" "supplemental" {
  bucket        = "${var.name_prefix}-bda-supp-${var.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "supplemental" {
  bucket                  = aws_s3_bucket.supplemental.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "supplemental" {
  bucket = aws_s3_bucket.supplemental.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

# --- GuardDuty S3 Malware Protection on Knowledge Documents Bucket (Control C9) ---

resource "aws_iam_role" "guardduty_malware" {
  name = "${var.name_prefix}-gd-malware-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "malware-protection-plan.guardduty.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "guardduty_malware" {
  name = "GuardDutyS3MalwareScanPolicy"
  role = aws_iam_role.guardduty_malware.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObjectTagging", "s3:ListBucket"]
        Resource = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_guardduty_malware_protection_plan" "source_docs" {
  role = aws_iam_role.guardduty_malware.arn

  protected_resource {
    s3_bucket {
      bucket_name = aws_s3_bucket.source.bucket
    }
  }

  actions {
    tagging {
      status = "ENABLED"
    }
  }

  depends_on = [aws_iam_role_policy.guardduty_malware]
}

# --- Amazon S3 Vectors (KMS CMK) ---

resource "aws_s3vectors_vector_bucket" "vectors" {
  vector_bucket_name = "${var.name_prefix}-vec"
  encryption_configuration {
    sse_type = "aws:kms"
    kms_key_arn = var.kms_key_arn
  }
}

resource "aws_s3vectors_index" "whitepapers" {
  vector_bucket_name = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
  index_name         = "whitepapers-index"
  data_type          = "float32"
  dimension          = 1024
  distance_metric    = "cosine"

  metadata_configuration {
    non_filterable_metadata_keys = ["AMAZON_BEDROCK_TEXT", "AMAZON_BEDROCK_METADATA"]
  }

  encryption_configuration {
    sse_type    = "aws:kms"
    kms_key_arn = var.kms_key_arn
  }
}

# --- Bedrock Knowledge Base & BDA Data Source ---

resource "aws_iam_role" "kb" {
  name = "${var.name_prefix}-kb-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock:${var.aws_region}:${var.account_id}:knowledge-base/*" }
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
          aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*",
          aws_s3_bucket.supplemental.arn, "${aws_s3_bucket.supplemental.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3vectors:*"]
        Resource = [aws_s3vectors_vector_bucket.vectors.vector_bucket_arn, aws_s3vectors_index.whitepapers.index_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

resource "aws_bedrockagent_knowledge_base" "main" {
  name     = "${var.name_prefix}-kb"
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

resource "aws_bedrockagent_data_source" "docs" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name              = "approved-docs-bda-source"

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

# --- Bedrock Guardrail with Contextual Grounding & Immutable Version (Controls C4, C7) ---

resource "aws_bedrock_guardrail" "main" {
  name                      = "${var.name_prefix}-guardrail"
  description               = "Input/output content filters, prompt-attack blocking, PII anonymization, and contextual grounding"
  blocked_input_messaging   = "Sorry, this request was blocked by AI safety guardrails."
  blocked_outputs_messaging = "Sorry, the response was blocked by AI safety or grounding guardrails."
  kms_key_arn               = var.kms_key_arn

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

  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.75
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = 0.75
    }
  }
}

resource "aws_bedrock_guardrail_version" "published" {
  guardrail_arn = aws_bedrock_guardrail.main.guardrail_arn
  description   = "Immutable production guardrail version"
}

output "kb_id" {
  value = aws_bedrockagent_knowledge_base.main.id
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.docs.data_source_id
}

output "source_bucket" {
  value = aws_s3_bucket.source.bucket
}

output "guardrail_id" {
  value = aws_bedrock_guardrail.main.guardrail_id
}

output "guardrail_version" {
  value = aws_bedrock_guardrail_version.published.version
}
