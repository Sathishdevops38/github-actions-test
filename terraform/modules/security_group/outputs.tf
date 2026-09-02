output "runner_sg_id" {
  description = "ID of the runner security group."
  value       = aws_security_group.runner.id
}

output "runner_sg_arn" {
  description = "ARN of the runner security group."
  value       = aws_security_group.runner.arn
}
