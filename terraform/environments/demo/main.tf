# terraform/environments/demo/main.tf

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.region
  
  default_tags {
    tags = var.tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
    }
  }
}

# Networking Module
module "networking" {
  source = "../../modules/networking"
  
  name_prefix          = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  private_subnet_cidrs = local.private_subnet_cidrs
  public_subnet_cidrs  = local.public_subnet_cidrs
  enable_nat_gateway   = true
  region              = var.region
  tags                = local.common_tags
}

# IAM Module
module "iam" {
  source = "../../modules/iam"
  
  name_prefix           = local.name_prefix
  region               = var.region
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  tags                 = local.common_tags
}

# MSK Module
module "msk" {
  source = "../../modules/msk"
  
  name_prefix    = local.name_prefix
  vpc_id         = module.networking.vpc_id
  vpc_cidr       = var.vpc_cidr
  subnet_ids     = module.networking.private_subnet_ids
  kafka_version  = var.msk_kafka_version
  instance_type  = var.msk_instance_type
  broker_count   = var.msk_broker_count
  tags          = local.common_tags
}

# EKS Module
module "eks" {
  source = "../../modules/eks"
  
  name_prefix         = local.name_prefix
  cluster_version     = var.eks_cluster_version
  vpc_id              = module.networking.vpc_id
  subnet_ids          = module.networking.private_subnet_ids
  cluster_role_arn    = module.iam.eks_cluster_role_arn
  node_group_role_arn = module.iam.eks_node_group_role_arn
  node_groups         = var.eks_node_groups
  tags               = local.common_tags
}

# RDS Oracle Module
module "rds" {
  source = "../../modules/rds"
  
  name_prefix    = local.name_prefix
  vpc_id         = module.networking.vpc_id
  vpc_cidr       = var.vpc_cidr
  subnet_ids     = module.networking.private_subnet_ids
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class
  tags          = local.common_tags
}

# Redshift Module
module "redshift" {
  source = "../../modules/redshift"
  
  name_prefix         = local.name_prefix
  vpc_id              = module.networking.vpc_id
  vpc_cidr            = var.vpc_cidr
  subnet_ids          = module.networking.private_subnet_ids
  node_type           = var.redshift_node_type
  node_count          = var.redshift_node_count
  msk_cluster_arn     = module.msk.cluster_arn
  msk_access_role_arn = module.iam.redshift_msk_role_arn
  tags               = local.common_tags
}

# S3 Buckets
resource "aws_s3_bucket" "data" {
  bucket = "${local.name_prefix}-data-${data.aws_caller_identity.current.account_id}"
  
  tags = local.common_tags
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

resource "aws_s3_bucket" "backups" {
  bucket = "${local.name_prefix}-bkp-${data.aws_caller_identity.current.account_id}"
  
  tags = local.common_tags
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {} # Apply to all objects
    
    expiration {
      days = 90
    }
    
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-cdc-pipeline"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/MSK", "CpuUser", { stat = "Average" }],
            [".", "CpuIdle", { stat = "Average" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.region
          title   = "MSK CPU Utilization"
          period  = 300
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EKS", "cluster_node_count", { stat = "Average" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.region
          title   = "EKS Node Count"
          period  = 300
        }
      }
    ]
  })
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}
