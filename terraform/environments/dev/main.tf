locals {
  common_tags = {
    Project     = "github-actions-runners"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# --------------------------------------------------------------------------
# KMS key — pre-existing, managed outside Terraform.
# Looked up by the alias that was created manually.
# A separate alias is used for dev so dev and prod keys are isolated.
# --------------------------------------------------------------------------
data "aws_kms_alias" "runners" {
  name = "alias/gh-runner-dev-runner"
}

# --------------------------------------------------------------------------
# Secrets Manager — pre-existing, managed outside Terraform.
# Looked up by name; the secret value is populated manually via AWS CLI/Console.
# Uses a dev-specific secret so dev tokens never touch prod.
# --------------------------------------------------------------------------
data "aws_secretsmanager_secret" "github_token" {
  name = "/${var.name_prefix}/github-runner-token"
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
  github_token_secret_arn = data.aws_secretsmanager_secret.github_token.arn
  kms_key_arn             = data.aws_kms_alias.runners.target_key_arn
  extra_policy_arns       = var.extra_policy_arns
  tags                    = local.common_tags
}

# --------------------------------------------------------------------------
# EC2 Runners (Auto Scaling Group)
# --------------------------------------------------------------------------
module "ec2_runner" {
  source = "../../modules/ec2_runner"

  # CloudWatch Logs must wait until the KMS key policy authorizes its service
  # principal; both modules otherwise reference the same existing key directly.
  depends_on = [module.iam]

  name_prefix             = var.name_prefix
  ami_id                  = var.runner_ami_id
  instance_type           = var.runner_instance_type
  root_volume_size_gb     = var.runner_root_volume_size_gb
  subnet_ids              = module.vpc.private_subnet_ids
  security_group_id       = module.security_group.runner_sg_id
  instance_profile_name   = module.iam.runner_instance_profile_name
  kms_key_arn             = data.aws_kms_alias.runners.target_key_arn
  github_token_secret_arn = data.aws_secretsmanager_secret.github_token.arn
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
