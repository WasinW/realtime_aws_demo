variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "demo"
}

variable "owner_email" {
  description = "Owner email for tagging"
  type        = string
  default     = "team@example.com"
}

variable "cost_center" {
  description = "Cost center for tagging"
  type        = string
  default     = "engineering"
}

# VPC Configuration
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# Oracle RDS Configuration
variable "oracle_engine_version" {
  description = "Oracle engine version"
  type        = string
  default     = "19.0.0.0.ru-2023-10.rur-2023-10.r1"
}

variable "oracle_instance_class" {
  description = "Oracle instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "oracle_allocated_storage" {
  description = "Oracle allocated storage in GB"
  type        = number
  default     = 100
}

variable "oracle_master_username" {
  description = "Oracle master username"
  type        = string
  default     = "admin"
}

variable "oracle_master_password" {
  description = "Oracle master password"
  type        = string
  sensitive   = true
  default     = "OracleDemo123!"
}

# EKS Configuration
variable "eks_cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.27"
}

variable "eks_node_instance_type" {
  description = "EKS node instance type"
  type        = string
  default     = "t3.medium"
}

# EC2 Configuration
variable "ec2_instance_type" {
  description = "EC2 instance type for producer and consumer"
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 instances"
  type        = string
  default     = ""
}

# Redshift Configuration
variable "redshift_database_name" {
  description = "Redshift database name"
  type        = string
  default     = "cdcdemo"
}

variable "redshift_master_username" {
  description = "Redshift master username"
  type        = string
  default     = "admin"
}

variable "redshift_master_password" {
  description = "Redshift master password"
  type        = string
  sensitive   = true
  default     = "RedshiftDemo123!"
}
# เพิ่มตัวแปรนี้ใน variables.tf
variable "project_name" {
  description = "Project name"
  type        = string
  default     = "oracle-cdc-demo"
}