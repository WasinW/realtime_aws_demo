# terraform/environments/demo/variables.tf - Improved version for demo

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "oracle-cdc-pipeline"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "demo"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "tags" {
  description = "Default tags for all resources"
  type        = map(string)
  default = {
    Project     = "oracle-cdc-pipeline"
    Environment = "demo"
    ManagedBy   = "terraform"
    CostCenter  = "demo"
  }
}

# Deployment Options
variable "force_recreate" {
  description = "Force recreate all resources with new names"
  type        = bool
  default     = false
}

variable "single_az" {
  description = "Deploy in single AZ for cost savings (demo only)"
  type        = bool
  default     = true
}

# Feature Flags
variable "enable_eks" {
  description = "Enable EKS cluster deployment"
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Enable RDS Oracle deployment"
  type        = bool
  default     = true
}

variable "enable_redshift" {
  description = "Enable Redshift deployment"
  type        = bool
  default     = true
}

variable "enable_msk" {
  description = "Enable MSK deployment (false = use Kafka in K8s)"
  type        = bool
  default     = false
}

# VPC Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# EKS Configuration
variable "eks_cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "eks_node_groups" {
  description = "EKS node group configurations"
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
  default = {
    demo = {
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      instance_types = ["t3.medium"]
      labels = {
        role = "demo"
      }
      taints = []
    }
  }
}

# RDS Configuration
variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"
}

variable "rds_engine_version" {
  description = "Oracle engine version"
  type        = string
  default     = "19.0.0.0.ru-2023-10.rur-2023-10.r1"
}

# Redshift Configuration
variable "redshift_node_type" {
  description = "Redshift node type"
  type        = string
  default     = "ra3.xlplus"
}

variable "redshift_node_count" {
  description = "Number of Redshift nodes"
  type        = number
  default     = 1
}