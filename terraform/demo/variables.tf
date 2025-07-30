variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "oracle-cdc-demo"
}

# variable "key_pair_name" {
#   description = "EC2 key pair name for SSH access"
#   type        = string
# }

# Oracle RDS
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
}

# # MSK
# variable "msk_instance_type" {
#   description = "MSK instance type"
#   type        = string
#   default     = "kafka.m5.large"
# }

# variable "msk_ebs_volume_size" {
#   description = "MSK EBS volume size in GB"
#   type        = number
#   default     = 100
# }

# # EC2
# variable "ec2_instance_type" {
#   description = "EC2 instance type for producer and consumer"
#   type        = string
#   default     = "t3.medium"
# }

# Redshift
variable "redshift_master_username" {
  description = "Redshift master username"
  type        = string
  default     = "admin"
}

variable "redshift_master_password" {
  description = "Redshift master password"
  type        = string
  sensitive   = true
}
# variable "aws_region" {
#   description = "AWS region"
#   type        = string
#   default     = "ap-southeast-1"
# }

# variable "project_name" {
#   description = "Project name"
#   type        = string
#   default     = "oracle-cdc-demo"
# }

# variable "environment" {
#   description = "Environment name"
#   type        = string
#   default     = "demo"
# }

# variable "owner_email" {
#   description = "Owner email for tagging"
#   type        = string
#   default     = "team@example.com"
# }

# variable "cost_center" {
#   description = "Cost center for tagging"
#   type        = string
#   default     = "engineering"
# }

# # Oracle RDS
# variable "oracle_instance_class" {
#   description = "Oracle instance class"
#   type        = string
#   default     = "db.t3.medium"
# }

# variable "oracle_allocated_storage" {
#   description = "Oracle allocated storage in GB"
#   type        = number
#   default     = 100
# }

# variable "oracle_master_username" {
#   description = "Oracle master username"
#   type        = string
#   default     = "admin"
# }

# variable "oracle_master_password" {
#   description = "Oracle master password"
#   type        = string
#   sensitive   = true
# }

# # Redshift
# variable "redshift_master_username" {
#   description = "Redshift master username"
#   type        = string
#   default     = "admin"
# }

# variable "redshift_master_password" {
#   description = "Redshift master password"
#   type        = string
#   sensitive   = true
# }

# เพิ่มเฉพาะ 3 ตัวแปรนี้ที่ท้ายไฟล์ variables.tf ที่มีอยู่แล้ว

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