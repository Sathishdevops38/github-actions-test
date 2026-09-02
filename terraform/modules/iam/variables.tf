variable "name_prefix" {
  description = "Prefix applied to all IAM resource names."
  type        = string
}

variable "github_token_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret that stores the GitHub runner registration token."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the Secrets Manager secret."
  type        = string
}

variable "extra_policy_arns" {
  description = "Additional managed policy ARNs to attach to the runner IAM role (e.g. ECR, S3)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Map of tags applied to all resources."
  type        = map(string)
  default     = {}
}
