# Run this FIRST to create the S3 backend and DynamoDB lock table.
# Usage:
#   cd terraform/bootstrap-backend
#   terraform init
#   terraform apply

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "solana-cluster-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "Solana Cluster Terraform State"
    Environment = "private-testnet"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "solana-cluster-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Solana Cluster Terraform State Lock"
    Environment = "private-testnet"
    ManagedBy   = "terraform"
  }
}

output "state_bucket_name" {
  description = "S3 bucket for Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "DynamoDB table for state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}
