# terraform/modules/eks/variables.tf
variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS cluster"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for EKS cluster"
  type        = string
}

variable "node_group_role_arn" {
  description = "ARN of the IAM role for EKS node groups"
  type        = string
}

variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    min_size       = number
    max_size       = number
    desired_size   = number
    instance_types = list(string)
    labels         = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {}
}

variable "public_access_cidrs" {
  description = "CIDR blocks that can access the public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "kms_key_arn" {
  description = "KMS key ARN for EKS secrets encryption"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
