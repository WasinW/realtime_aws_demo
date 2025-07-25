# terraform/modules/redshift/variables.tf
variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for Redshift"
  type        = list(string)
}

variable "node_type" {
  description = "Redshift node type"
  type        = string
  default     = "dc2.large"
}

variable "node_count" {
  description = "Number of nodes in the cluster"
  type        = number
  default     = 2
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  type        = string
}

variable "msk_access_role_arn" {
  description = "ARN of the IAM role for MSK access"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
