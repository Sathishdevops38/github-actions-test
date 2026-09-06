variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, prod)."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure."
  type        = string
  default     = "individual"
}

variable "name_prefix" {
  description = "Short prefix prepended to every resource name."
  type        = string
  default     = "gh-runner-dev"
}

# ── Networking ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (NAT Gateways)."
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets (runner instances)."
  type        = list(string)
  default     = ["10.1.11.0/24", "10.1.12.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to use (must match subnet count)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "allow_intra_sg_communication" {
  description = "Allow runner instances to communicate with each other."
  type        = bool
  default     = false
}

# ── IAM ──────────────────────────────────────────────────────────────────────

variable "extra_policy_arns" {
  description = "Additional managed policy ARNs to attach to the runner role."
  type        = list(string)
  default     = []
}

# ── GitHub ───────────────────────────────────────────────────────────────────

variable "github_owner" {
  description = "GitHub organisation or user name."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name. Leave empty string to register the runner at org level (visible to all repos). Set to a repo name for repo-level registration (visible to that repo only)."
  type        = string
  default     = ""
}

variable "runner_group" {
  description = "GitHub Actions runner group name."
  type        = string
  default     = "default"
}

variable "runner_version" {
  description = "GitHub Actions runner binary version."
  type        = string
  default     = "2.337.0"
}

variable "runner_os" {
  description = "OS label for the runner (linux | windows)."
  type        = string
  default     = "linux"
}

variable "runner_arch" {
  description = "Architecture label for the runner (x64 | arm64)."
  type        = string
  default     = "x64"
}

variable "extra_runner_labels" {
  description = "Additional runner labels."
  type        = list(string)
  default     = []
}

variable "ephemeral_runners" {
  description = "Each runner handles one job then terminates."
  type        = bool
  default     = true
}

# ── EC2 ──────────────────────────────────────────────────────────────────────

variable "runner_ami_id" {
  description = "AMI ID for runner instances (Amazon Linux 2023 recommended)."
  type        = string
}

variable "runner_instance_type" {
  description = "EC2 instance type for runners. Dev uses a smaller instance than prod."
  type        = string
  default     = "t3.small"
}

variable "runner_root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "min_runners" {
  description = "Minimum ASG capacity."
  type        = number
  default     = 0
}

variable "max_runners" {
  description = "Maximum ASG capacity."
  type        = number
  default     = 3
}

variable "desired_runners" {
  description = "Initial desired ASG capacity."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 30
}
