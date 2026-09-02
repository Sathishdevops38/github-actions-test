output "vpc_id" {
  description = "ID of the runner VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets used by runner instances."
  value       = module.vpc.private_subnet_ids
}

output "runner_sg_id" {
  description = "ID of the runner security group."
  value       = module.security_group.runner_sg_id
}

output "runner_role_arn" {
  description = "ARN of the IAM role attached to runner instances."
  value       = module.iam.runner_role_arn
}

output "runner_instance_profile_name" {
  description = "Name of the EC2 instance profile."
  value       = module.iam.runner_instance_profile_name
}

output "autoscaling_group_name" {
  description = "Name of the runner Auto Scaling Group."
  value       = module.ec2_runner.autoscaling_group_name
}

output "launch_template_id" {
  description = "ID of the runner launch template."
  value       = module.ec2_runner.launch_template_id
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch Log Group for runner bootstrap logs."
  value       = module.ec2_runner.cloudwatch_log_group_name
}

output "github_token_secret_arn" {
  description = "ARN of the Secrets Manager secret for the GitHub runner token."
  value       = aws_secretsmanager_secret.github_token.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key protecting runner resources."
  value       = data.aws_kms_alias.runners.target_key_arn
}
