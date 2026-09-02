output "launch_template_id" {
  description = "ID of the runner launch template."
  value       = aws_launch_template.runner.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the runner launch template."
  value       = aws_launch_template.runner.latest_version
}

output "autoscaling_group_name" {
  description = "Name of the runner Auto Scaling Group."
  value       = aws_autoscaling_group.runner.name
}

output "autoscaling_group_arn" {
  description = "ARN of the runner Auto Scaling Group."
  value       = aws_autoscaling_group.runner.arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Log Group for runner bootstrap output."
  value       = aws_cloudwatch_log_group.runner.name
}
