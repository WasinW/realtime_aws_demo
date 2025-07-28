variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "oracle-cdc-pipeline"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "demo"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "force_recreate" {
  description = "Force recreate resources"
  type        = bool
  default     = false
}

variable "enable_eks" {
  description = "Enable EKS"
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
