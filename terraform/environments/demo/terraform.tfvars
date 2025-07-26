# terraform/environments/demo/terraform.tfvars.example
# Copy this file to terraform.tfvars and update the values

project_name = "oracle-cdc-pipeline"
environment  = "demo"
region       = "ap-southeast-1"

# Make sure all resources are tagged for cost tracking
tags = {
  Project     = "demo_rt_the_one"
  Environment = "demo"
  ManagedBy   = "terraform"
  CostCenter  = "demo_rt_the_one"
  Owner       = "wasin.wangsombut@global.ntt"
}

# VPC Configuration
vpc_cidr = "10.0.0.0/16"
# azs      = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
azs = ["ap-southeast-1a"]

# EKS Configuration
eks_cluster_version = "1.29"
eks_node_groups = {
  debezium = {
    min_size       = 1
    max_size       = 2
    desired_size   = 1
    # instance_types = ["m5.xlarge"]
    instance_types = ["t3.medium"]
    labels = {
      role = "demo"
    }
    taints = []
  }
}

# MSK Configuration
# msk_instance_type = "kafka.m5.large"
msk_instance_type = "kafka.t3.small"
msk_kafka_version = "3.5.1"
msk_broker_count  = 3

# RDS Configuration (Oracle)
# rds_instance_class = "db.m5.xlarge"
rds_instance_class = "db.t3.small"
rds_engine_version = "19.0.0.0.ru-2023-10.rur-2023-10.r1"

# Redshift Configuration
redshift_node_type  = "ra3.large"
redshift_node_count = 1