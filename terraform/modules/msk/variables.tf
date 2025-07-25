# terraform/modules/msk/variables.tf
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
  description = "Subnet IDs for MSK brokers"
  type        = list(string)
}

variable "kafka_version" {
  description = "Kafka version"
  type        = string
  default     = "3.5.1"
}

variable "instance_type" {
  description = "Instance type for MSK brokers"
  type        = string
  default     = "kafka.m5.large"
}

variable "broker_count" {
  description = "Number of broker nodes"
  type        = number
  default     = 3
}

variable "ebs_volume_size" {
  description = "EBS volume size in GB"
  type        = number
  default     = 1000
}

variable "enable_provisioned_throughput" {
  description = "Enable provisioned throughput"
  type        = bool
  default     = false
}

variable "provisioned_throughput" {
  description = "Provisioned throughput in MiB/s"
  type        = number
  default     = 250
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption at rest"
  type        = string
  default     = ""
}

variable "initial_topics" {
  description = "Initial topics to create"
  type        = list(string)
  default = [
    "oracle.inventory.customers",
    "oracle.inventory.products",
    "oracle.inventory.orders",
    "oracle.inventory.customers.masked",
    "oracle.inventory.products.masked",
    "oracle.inventory.orders.masked"
  ]
}

variable "default_partitions" {
  description = "Default number of partitions for topics"
  type        = number
  default     = 10
}

variable "default_replication_factor" {
  description = "Default replication factor for topics"
  type        = number
  default     = 3
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

