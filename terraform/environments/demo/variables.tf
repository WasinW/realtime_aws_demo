# terraform/environments/demo/variables.tf

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
    Project     = "demo_rt_the_one"
    Environment = "demo"
    ManagedBy   = "terraform"
    CostCenter  = "demo_rt_the_one"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

# EKS Configuration
variable "eks_cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "eks_node_groups" {
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
  default = {
    debezium = {
      min_size       = 2
      max_size       = 5
      desired_size   = 3
      instance_types = ["m5.xlarge"]
      labels = {
        role = "debezium-worker"
      }
      taints = []
    }
  }
}

# MSK Configuration
variable "msk_instance_type" {
  description = "Instance type for MSK brokers"
  type        = string
  default     = "kafka.m5.large"
}

variable "msk_kafka_version" {
  description = "Kafka version for MSK"
  type        = string
  default     = "3.5.1"
}

variable "msk_broker_count" {
  description = "Number of broker nodes in MSK cluster"
  type        = number
  default     = 3
}

# RDS Configuration
variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.m5.xlarge"
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
  description = "Number of nodes in Redshift cluster"
  type        = number
  default     = 2
}