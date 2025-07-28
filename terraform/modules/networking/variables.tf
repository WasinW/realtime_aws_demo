# terraform/modules/networking/variables.tf
variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets"
  type        = bool
  default     = true
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "single_nat_gateway" {
  description = "Use single NAT Gateway for all AZs (cost saving)"
  type        = bool
  default     = false
}

variable "create_vpc_endpoints" {
  description = "Create VPC endpoints for S3 and ECR"
  type        = bool
  default     = false  # ไม่ต้องการสำหรับ demo
}

variable "create_vpc" {
  description = "Whether to create VPC. If false, will use existing VPC"
  type        = bool
  default     = true
}
