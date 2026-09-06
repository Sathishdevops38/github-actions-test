terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  # hello Remote state stored in S3 with native S3 locking (Terraform >= 1.10).
  # No DynamoDB table required — S3 handles the lock file directly.
  # Values are supplied via -backend-config flags in CI or a backend.hcl file.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
