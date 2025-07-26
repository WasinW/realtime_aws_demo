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
  default     = "ra3.large"
}

variable "node_count" {
  description = "Number of nodes in the cluster"
  type        = number
  default     = 1
}

# Make MSK optional
variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  type        = string
  default     = ""
}

variable "msk_access_role_arn" {
  description = "ARN of the IAM role for MSK access"
  type        = string
  default     = ""
}

variable "multi_az" {
  description = "Deploy Redshift in multiple AZs"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
