locals {
  common_tags = {
    Project     = "github-actions-runners"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# --------------------------------------------------------------------------
# KMS key — encrypts EBS volumes, Secrets Manager secrets, CloudWatch Logs
# --------------------------------------------------------------------------
resource "aws_kms_key" "runners" {
  description             = "KMS key for GitHub Actions runner resources"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  tags = {
    Name = "${var.name_prefix}-runner-kms"
  }
}

resource "aws_kms_alias" "runners" {
  name          = "alias/${var.name_prefix}-runner"
  target_key_id = aws_kms_key.runners.key_id
}

# --------------------------------------------------------------------------
# Secrets Manager — GitHub runner registration token
# Store the token via AWS CLI / Console; Terraform only references the ARN.
# aws secretsmanager create-secret \
#   --name /github-actions/runner-token \
#   --secret-string "<YOUR_GITHUB_PAT_WITH_REPO_SCOPE>"
# --------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "github_token" {
  name                    = "/${var.name_prefix}/github-runner-token"
  description             = "GitHub Actions runner registration token / PAT"
  kms_key_id              = aws_kms_key.runners.arn
  recovery_window_in_days = 7

  tags = {
    Name = "${var.name_prefix}-github-runner-token"
  }
}

# --------------------------------------------------------------------------
# Networking
# --------------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  name_prefix          = var.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  tags                 = local.common_tags
}

# --------------------------------------------------------------------------
# Security Group
# --------------------------------------------------------------------------
module "security_group" {
  source = "../../modules/security_group"

  name_prefix                  = var.name_prefix
  vpc_id                       = module.vpc.vpc_id
  allow_intra_sg_communication = var.allow_intra_sg_communication
  tags                         = local.common_tags
}

# --------------------------------------------------------------------------
# IAM
# --------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  name_prefix             = var.name_prefix
  github_token_secret_arn = aws_secretsmanager_secret.github_token.arn
  kms_key_arn             = aws_kms_key.runners.arn
  extra_policy_arns       = var.extra_policy_arns
  tags                    = local.common_tags
}

# --------------------------------------------------------------------------
# EC2 Runners (Auto Scaling Group)
# --------------------------------------------------------------------------
module "ec2_runner" {
  source = "../../modules/ec2_runner"

  name_prefix             = var.name_prefix
  ami_id                  = var.runner_ami_id
  instance_type           = var.runner_instance_type
  root_volume_size_gb     = var.runner_root_volume_size_gb
  subnet_ids              = module.vpc.private_subnet_ids
  security_group_id       = module.security_group.runner_sg_id
  instance_profile_name   = module.iam.runner_instance_profile_name
  kms_key_arn             = aws_kms_key.runners.arn
  github_token_secret_arn = aws_secretsmanager_secret.github_token.arn
  github_owner            = var.github_owner
  github_repo             = var.github_repo
  runner_group            = var.runner_group
  runner_version          = var.runner_version
  runner_os               = var.runner_os
  runner_arch             = var.runner_arch
  extra_runner_labels     = var.extra_runner_labels
  ephemeral_runners       = var.ephemeral_runners
  min_runners             = var.min_runners
  max_runners             = var.max_runners
  desired_runners         = var.desired_runners
  log_retention_days      = var.log_retention_days
  tags                    = local.common_tags
}
