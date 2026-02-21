data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "loki" {
  # S3 buckets must be globally unique, so we append the AWS account ID
  bucket        = "${var.project_name}-loki-${data.aws_caller_identity.current.account_id}-${var.environment}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-loki-${var.environment}"
  }
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30 # Retain logs for 30 days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
