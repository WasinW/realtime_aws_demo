# terraform/environments/demo/main.tf - Fixed version

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
# Data source to check existing resources
data "aws_resourcegroupstaggingapi_resources" "existing" {
  tag_filter {
    key    = "Project"
    values = ["oracle-cdc-pipeline"]
  }
}

locals {
  name_prefix = "oracle-cdc-demo"
  vpc_cidr    = "10.0.0.0/16"  # เพิ่มบรรทัดนี้

  # Check for existing resources
  existing_vpcs = [for r in data.aws_resourcegroupstaggingapi_resources.existing.resource_tag_mapping_list : r.resource_arn if can(regex("^arn:aws:ec2:.*:vpc/", r.resource_arn))]
  vpc_exists = length(local.existing_vpcs) > 0
  
  # Generate unique suffix for resources
  resource_suffix = var.force_recreate ? random_string.suffix[0].result : ""
  
  # Single AZ for demo
  # azs = var.single_az ? [data.aws_availability_zones.available.names[0]] : data.aws_availability_zones.available.names
  
  # Resource naming
  # name_prefix = "${var.project_name}-${var.environment}${local.resource_suffix != "" ? "-${local.resource_suffix}" : ""}"

}

# Random suffix for unique naming when recreating
resource "random_string" "suffix" {
  count   = var.force_recreate ? 1 : 0
  length  = 4
  special = false
  upper   = false
}

# Data source for AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

provider "aws" {
  region = var.region
  
  default_tags {
    tags = {
      Project     = "oracle-cdc-pipeline"
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}

# VPC Module - Create only if doesn't exist
# module "vpc" {
#   count  = local.vpc_exists && !var.force_recreate ? 0 : 1
#   source = "../../modules/networking"
  
#   name_prefix          = local.name_prefix
#   vpc_cidr            = var.vpc_cidr
#   azs                 = local.azs
#   private_subnet_cidrs = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
#   public_subnet_cidrs  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
#   enable_nat_gateway   = true
#   region              = var.region
#   tags                = var.tags
# }
# VPC Module
module "vpc" {
  source = "../../modules/networking"  # เปลี่ยนเป็น networking
  
  name_prefix = local.name_prefix
  vpc_cidr    = local.vpc_cidr
  
  # Single AZ for demo
  azs = ["${var.region}a"]
  
  # Subnet CIDRs
  private_subnet_cidrs = [cidrsubnet(local.vpc_cidr, 4, 0)]
  public_subnet_cidrs  = [cidrsubnet(local.vpc_cidr, 4, 8)]
  
  # Single NAT Gateway for cost saving
  enable_nat_gateway = true
  
  region = var.region
  tags   = var.tags
}

# Use existing VPC data if available
data "aws_vpc" "existing" {
  count = local.vpc_exists && !var.force_recreate ? 1 : 0
  
  filter {
    name   = "tag:Project"
    values = [var.project_name]
  }
}

# Data source for existing subnets
data "aws_subnets" "existing_private" {
  count = local.vpc_exists && !var.force_recreate ? 1 : 0
  
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing[0].id]
  }
  
  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

# IAM Module
# IAM Module
module "iam" {
  source = "../../modules/iam"
  
  name_prefix           = local.name_prefix
  region               = var.region
  eks_oidc_provider_arn = module.eks.oidc_provider_arn  # ใช้จาก EKS โดยตรง
  tags                 = var.tags
}

# EKS Module - Optional
# module "eks" {
#   count  = var.enable_eks ? 1 : 0
#   source = "../../modules/eks"
  
#   name_prefix         = local.name_prefix
#   cluster_version     = var.eks_cluster_version
#   vpc_id              = local.vpc_exists && !var.force_recreate ? data.aws_vpc.existing[0].id : module.vpc[0].vpc_id
#   subnet_ids          = local.vpc_exists && !var.force_recreate ? data.aws_subnets.existing_private[0].ids : module.vpc[0].private_subnet_ids
#   cluster_role_arn    = module.iam.eks_cluster_role_arn
#   node_group_role_arn = module.iam.eks_node_group_role_arn
#   node_groups         = var.eks_node_groups
#   tags               = var.tags
# }
module "eks" {
  source = "../../modules/eks"
  
  name_prefix     = local.name_prefix
  cluster_version = "1.29"
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids
  
  # เพิ่ม IAM roles
  cluster_role_arn    = module.iam.eks_cluster_role_arn
  node_group_role_arn = module.iam.eks_node_group_role_arn
  
  # Single node group for demo
  node_groups = {
    demo = {
      desired_size   = 1
      min_size       = 1
      max_size       = 2
      instance_types = ["t3.medium"]
      labels         = {}
      taints         = []
    }
  }
  
  tags = var.tags
}
# RDS Oracle Module - Optional
# module "rds" {
#   count  = var.enable_rds ? 1 : 0
#   source = "../../modules/rds"
  
#   name_prefix    = local.name_prefix
#   vpc_id         = local.vpc_exists && !var.force_recreate ? data.aws_vpc.existing[0].id : module.vpc[0].vpc_id
#   vpc_cidr       = var.vpc_cidr
#   subnet_ids     = local.vpc_exists && !var.force_recreate ? data.aws_subnets.existing_private[0].ids : module.vpc[0].private_subnet_ids
#   engine_version = var.rds_engine_version
#   instance_class = var.rds_instance_class
#   tags          = var.tags
# }
module "rds" {
  source = "../../modules/rds"
  
  name_prefix = local.name_prefix
  
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = local.vpc_cidr  # เพิ่มบรรทัดนี้
  subnet_ids = module.vpc.private_subnet_ids
  
  # Small instance for demo
  instance_class          = "db.t3.small"
  allocated_storage       = 100
  max_allocated_storage   = 200
  
  tags = var.tags
}

# Redshift Module - Optional (ไม่ต้องส่ง MSK parameters)
# module "redshift" {
#   count  = var.enable_redshift ? 1 : 0
#   source = "../../modules/redshift"
  
#   name_prefix = local.name_prefix
#   vpc_id      = local.vpc_exists && !var.force_recreate ? data.aws_vpc.existing[0].id : module.vpc[0].vpc_id
#   vpc_cidr    = var.vpc_cidr
#   subnet_ids  = local.vpc_exists && !var.force_recreate ? data.aws_subnets.existing_private[0].ids : module.vpc[0].private_subnet_ids
#   node_type   = var.redshift_node_type
#   node_count  = var.redshift_node_count
#   tags        = var.tags
# }
module "redshift" {
  source = "../../modules/redshift"
  
  name_prefix = local.name_prefix
  
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = local.vpc_cidr  # เพิ่มบรรทัดนี้
  subnet_ids = module.vpc.private_subnet_ids
  
  # Single node for demo
  node_type  = "ra3.xlplus"
  node_count = 1
  
  tags = var.tags
}

# S3 Buckets with versioning for safety
resource "aws_s3_bucket" "data" {
  bucket = "${local.name_prefix}-data-${data.aws_caller_identity.current.account_id}"
  
  lifecycle {
    prevent_destroy = false
  }
  
  tags = var.tags
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-dashboard"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "cluster_node_count", { stat = "Average" }]
          ]
          view    = "timeSeries"
          region  = var.region
          title   = "EKS Node Count"
          period  = 300
        }
      }
    ]
  })
}

# Outputs for other scripts
# output "deployment_info" {
#   value = {
#     vpc_id              = local.vpc_exists && !var.force_recreate ? data.aws_vpc.existing[0].id : try(module.vpc[0].vpc_id, "")
#     eks_cluster_id      = try(module.eks[0].cluster_id, "")
#     eks_cluster_endpoint = try(module.eks[0].cluster_endpoint, "")
#     rds_endpoint        = try(module.rds[0].endpoint, "")
#     redshift_endpoint   = try(module.redshift[0].endpoint, "")
#     s3_bucket          = aws_s3_bucket.data.id
#     resource_suffix    = local.resource_suffix
#   }
# }

# Create marker file for successful deployment
# resource "local_file" "deployment_marker" {
#   filename = "${path.module}/.deployment_complete"
#   content  = jsonencode({
#     timestamp = timestamp()
#     suffix    = local.resource_suffix
#     vpc_id    = local.vpc_exists && !var.force_recreate ? data.aws_vpc.existing[0].id : try(module.vpc[0].vpc_id, "")
#   })
# }