variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "ami_id" {
  description = "AMI ID for runner instances (Amazon Linux 2023 or similar)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for runners."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Size in GiB of the root EBS volume."
  type        = number
  default     = 30
}

variable "subnet_ids" {
  description = "IDs of the subnets in which the ASG launches instances (private preferred)."
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the security group attached to runner instances."
  type        = string
}

variable "instance_profile_name" {
  description = "Name of the IAM instance profile for runner instances."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt EBS volumes, CloudWatch Logs, and Secrets Manager secrets."
  type        = string
}

variable "github_token_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret containing the GitHub runner registration token."
  type        = string
}

variable "github_owner" {
  description = "GitHub organisation or user name that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without owner prefix). Leave empty to register at org level."
  type        = string
  default     = ""
}

variable "runner_group" {
  description = "Name of the GitHub Actions runner group."
  type        = string
  default     = "default"
}

variable "runner_version" {
  description = "Version of the GitHub Actions runner binary to install (e.g. 2.317.0)."
  type        = string
  default     = "2.336.0"
}

variable "runner_os" {
  description = "OS label added to the runner (linux | windows)."
  type        = string
  default     = "linux"
}

variable "runner_arch" {
  description = "Architecture label added to the runner (x64 | arm64)."
  type        = string
  default     = "x64"
}

variable "extra_runner_labels" {
  description = "Additional labels to attach to the runner."
  type        = list(string)
  default     = []
}

variable "ephemeral_runners" {
  description = "When true, each runner instance handles a single job then de-registers (recommended)."
  type        = bool
  default     = true
}

variable "min_runners" {
  description = "Minimum number of runner instances in the ASG."
  type        = number
  default     = 1
}

variable "max_runners" {
  description = "Maximum number of runner instances in the ASG."
  type        = number
  default     = 10
}

variable "desired_runners" {
  description = "Desired number of runner instances at launch."
  type        = number
  default     = 2
}

variable "log_retention_days" {
  description = "Number of days to retain runner bootstrap logs in CloudWatch."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Map of tags applied to all resources."
  type        = map(string)
  default     = {}
}
