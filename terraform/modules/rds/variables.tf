# terraform/modules/rds/variables.tf
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
  description = "Subnet IDs for RDS"
  type        = list(string)
}

variable "engine_version" {
  description = "Oracle engine version"
  type        = string
  default     = "19.0.0.0.ru-2023-10.rur-2023-10.r1"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.m5.xlarge"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "Maximum allocated storage in GB"
  type        = number
  default     = 1000
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 1  # Minimal for demo
}

variable "multi_az" {
  description = "Enable Multi-AZ"
  type        = bool
  default     = false  # Single AZ for demo
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false  # Easy cleanup for demo
}