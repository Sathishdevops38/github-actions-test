output "runner_role_arn" {
  description = "ARN of the IAM role attached to runner instances."
  value       = aws_iam_role.runner.arn
}

output "runner_role_name" {
  description = "Name of the IAM role attached to runner instances."
  value       = aws_iam_role.runner.name
}

output "runner_instance_profile_name" {
  description = "Name of the EC2 instance profile for runner instances."
  value       = aws_iam_instance_profile.runner.name
}

output "runner_instance_profile_arn" {
  description = "ARN of the EC2 instance profile for runner instances."
  value       = aws_iam_instance_profile.runner.arn
}
