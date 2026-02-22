terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Note: The 'bucket' and 'dynamodb_table' values here must match the 
  # output of the bootstrap-state.sh script. Because Terraform backend 
  # config doesn't allow variables, these are hardcoded. If you change 
  # the script defaults, you must change them here.
  backend "s3" {
    bucket         = "otel-enterprise-tf-state-6118696b"
    key            = "global/s3/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "otel-enterprise-tf-locks"
    encrypt        = true
  }

}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "Enterprise-OTel-Stack"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
