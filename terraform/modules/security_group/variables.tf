variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the security group will be created."
  type        = string
}

variable "allow_intra_sg_communication" {
  description = "Whether to allow runner instances in the same security group to communicate with each other."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Map of tags applied to all resources."
  type        = map(string)
  default     = {}
}
