# backend.hcl — supply values here or pass via -backend-config CLI flags.
# Never commit real bucket names / account IDs to this file.
# Reference: https://developer.hashicorp.com/terraform/language/settings/backends/s3
#
# S3 native locking is used (Terraform >= 1.10, AWS provider >= 5.38).
# No DynamoDB table is required.

bucket         = "YOUR_TF_STATE_BUCKET_NAME"
key            = "github-actions-runners/prod/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
kms_key_id     = "alias/terraform-state"
use_lockfile   = true
