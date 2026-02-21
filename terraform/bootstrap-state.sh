#!/usr/bin/env bash
set -e

# ==============================================================================
# Terraform Remote State Bootstrap Script
# ==============================================================================
# This script provisions the S3 Bucket and DynamoDB table required for Terraform
# to store its remote state and manage concurrency locks securely.
#
# It should be run ONCE per AWS account/environment before running `terraform init`.
# ==============================================================================

# Default values - can be overridden by environment variables
AWS_REGION=${AWS_REGION:-"ap-southeast-2"}
TF_STATE_BUCKET=${TF_STATE_BUCKET:-"otel-enterprise-tf-state-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d'-' -f1)"}
DYNAMODB_TABLE="otel-enterprise-tf-locks"

echo "========================================="
echo "☁️  Bootstrapping Terraform Remote State"
echo "========================================="
echo "Region:         $AWS_REGION"
echo "S3 Bucket:      $TF_STATE_BUCKET"
echo "DynamoDB Table: $DYNAMODB_TABLE"
echo "========================================="

# 1. Check AWS Authentication
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ Error: AWS CLI is not authenticated. Please run 'aws sso login' or set credentials."
    exit 1
fi
echo "✅ AWS authentication verified."

# 2. Create S3 Bucket (if it doesn't already exist)
if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
    echo "✅ S3 Bucket '$TF_STATE_BUCKET' already exists."
else
    echo "Creating S3 Bucket '$TF_STATE_BUCKET'..."
    # Specific LocationConstraint syntax required for regions outside us-east-1
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
    echo "✅ S3 Bucket created."

    # Enable Versioning (Critical for Terraform state history/recovery)
    echo "Enabling versioning on bucket..."
    aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" --versioning-configuration Status=Enabled > /dev/null
    echo "✅ Versioning enabled."
    
    # Block Public Access (Security Best Practice)
    echo "Blocking public access to bucket..."
    aws s3api put-public-access-block \
        --bucket "$TF_STATE_BUCKET" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" > /dev/null
    echo "✅ Public access blocked."
fi

# 3. Create DynamoDB Lock Table (if it doesn't already exist)
if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "✅ DynamoDB Table '$DYNAMODB_TABLE' already exists."
else
    echo "Creating DynamoDB Table '$DYNAMODB_TABLE'..."
    aws dynamodb create-table \
        --table-name "$DYNAMODB_TABLE" \
        --region "$AWS_REGION" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST > /dev/null
    
    echo "Waiting for table to become active..."
    aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION"
    echo "✅ DynamoDB Table created."
fi

echo "========================================="
echo "🎉 Bootstrap Complete!"
echo "========================================="
echo "To use this backend, ensure your terraform/backend.tf looks like this:"
echo ""
echo "terraform {"
echo "  backend \"s3\" {"
echo "    bucket         = \"$TF_STATE_BUCKET\""
echo "    key            = \"global/s3/terraform.tfstate\""
echo "    region         = \"$AWS_REGION\""
echo "    dynamodb_table = \"$DYNAMODB_TABLE\""
echo "    encrypt        = true"
echo "  }"
echo "}"
echo "========================================="
