# Module: Private KMS-encrypted S3 Bucket for React SPA served strictly via S3 Interface VPCE

variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "s3_interface_vpce_id" {
  type = string
}

resource "aws_s3_bucket" "spa" {
  bucket        = "${var.name_prefix}-spa-${var.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_policy" "spa_vpce_only" {
  bucket = aws_s3_bucket.spa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.spa.arn, "${aws_s3_bucket.spa.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AllowReadViaS3InterfaceVpceOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.spa.arn}/*"
        Condition = { StringEquals = { "aws:SourceVpce" = var.s3_interface_vpce_id } }
      },
    ]
  })
}

output "spa_bucket_name" {
  value = aws_s3_bucket.spa.bucket
}
