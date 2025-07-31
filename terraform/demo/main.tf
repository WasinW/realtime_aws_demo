# terraform {
#   required_version = ">= 1.5.0"
  
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#     kubernetes = {
#       source  = "hashicorp/kubernetes"
#       version = "~> 2.23"
#     }
#     helm = {
#       source  = "hashicorp/helm"
#       version = "~> 2.11"
#     }
#   }
# }

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "oracle-cdc-pipeline"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_email
      CostCenter  = var.cost_center
    }
  }
}

# Local variables
locals {
  common_tags = {
    Project     = "oracle-cdc-pipeline"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner_email
    CostCenter  = var.cost_center
    CreatedDate = formatdate("YYYY-MM-DD", timestamp())
  }
  
  name_prefix = "oracle-cdc-demo"
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Random suffix for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# VPC Configuration
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  
  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs
  
  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true
  
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    Project = "oracle-cdc-pipeline"
  }
  
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    Project = "oracle-cdc-pipeline"
  }
  
  tags = local.common_tags
}

# Security Group for all components
resource "aws_security_group" "demo_sg" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for Oracle CDC Demo"
  vpc_id      = module.vpc.vpc_id
  
  # Allow all ingress from within VPC
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "Allow all from VPC"
  }
  
  # Allow Oracle port from anywhere (for demo)
  ingress {
    from_port   = 1521
    to_port     = 1521
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Oracle DB"
  }
  
  # Allow Kafka ports from anywhere (for demo)
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka"
  }
  
  # Allow SSH from anywhere (for demo)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  # Allow all egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sg"
  })
}

# Oracle RDS Instance
resource "aws_db_subnet_group" "oracle" {
  name       = "${local.name_prefix}-oracle"
  subnet_ids = module.vpc.public_subnets
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-oracle-subnet-group"
  })
}

resource "aws_db_instance" "oracle" {
  identifier = "${local.name_prefix}-oracle"
  
  engine         = "oracle-ee"
  engine_version = var.oracle_engine_version
  instance_class = var.oracle_instance_class
  
  allocated_storage = var.oracle_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = false
  
  db_name  = "CDCDEMO"
  username = var.oracle_master_username
  password = var.oracle_master_password
  
  db_subnet_group_name   = aws_db_subnet_group.oracle.name
  vpc_security_group_ids = [aws_security_group.demo_sg.id]
  
  publicly_accessible = true
  skip_final_snapshot = true
  deletion_protection = false
  
  backup_retention_period = 1
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-oracle"
    Component = "Database"
  })
}

# EKS Cluster for Kafka
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"  # อัพเดตเป็น version 20
  
  cluster_name    = "${local.name_prefix}-eks"
  cluster_version = var.eks_cluster_version
  
  # เปลี่ยนจาก vpc_id และ subnet_ids
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  
  # ใช้ control_plane_subnet_ids แทน
  control_plane_subnet_ids = module.vpc.private_subnets
  
  cluster_endpoint_public_access = true
  
  # Enable cluster creator admin permissions
#   enable_cluster_creator_admin_permissions = true
  
  # Node groups configuration ที่อัพเดตแล้ว
  eks_managed_node_groups = {
    kafka = {
      min_size     = 3
      max_size     = 3
      desired_size = 3
      
      instance_types = [var.eks_node_instance_type]
      
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
      
      tags = merge(local.common_tags, {
        Name = "${local.name_prefix}-eks-kafka-node"
      })
    }
  }

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  tags = local.common_tags
}

# Configure kubectl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name
      ]
    }
  }
}

# S3 Buckets
resource "aws_s3_bucket" "data_bucket" {
  bucket = "${local.name_prefix}-data-${random_string.suffix.result}"
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-data"
    Component = "Storage"
    Purpose = "CDC Data"
  })
}

resource "aws_s3_bucket" "dlq_bucket" {
  bucket = "${local.name_prefix}-dlq-${random_string.suffix.result}"
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-dlq"
    Component = "Storage"
    Purpose = "Dead Letter Queue"
  })
}

resource "aws_s3_bucket_public_access_block" "data_bucket" {
  bucket = aws_s3_bucket.data_bucket.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "dlq_bucket" {
  bucket = aws_s3_bucket.dlq_bucket.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Redshift Serverless
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${local.name_prefix}-namespace"
  db_name            = var.redshift_database_name
  admin_username     = var.redshift_master_username
  admin_user_password = var.redshift_master_password
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redshift-namespace"
    Component = "Analytics"
  })
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${local.name_prefix}-workgroup"
  
  base_capacity = 32
  publicly_accessible = true
  
  subnet_ids = module.vpc.public_subnets
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redshift-workgroup"
    Component = "Analytics"
  })
}

# IAM Role for EC2 instances
resource "aws_iam_role" "ec2_role" {
  name = "${local.name_prefix}-ec2-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "${local.name_prefix}-ec2-policy"
  role = aws_iam_role.ec2_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:*",
          "kafka:*",
          "redshift:*",
          "logs:*",
          "cloudwatch:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
  
  tags = local.common_tags
}

# Key Pair for EC2 instances
resource "aws_key_pair" "demo" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key
  
  tags = local.common_tags
}

# Producer EC2 Instance
resource "aws_instance" "producer" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = var.ec2_instance_type
  
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.demo_sg.id]
  associate_public_ip_address = true
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  key_name            = aws_key_pair.demo.key_name
  
  user_data = templatefile("${path.module}/userdata/producer_setup.sh", {
    oracle_endpoint  = aws_db_instance.oracle.endpoint
    oracle_username  = var.oracle_master_username
    oracle_password  = var.oracle_master_password
    kafka_bootstrap  = "${module.eks.cluster_name}-kafka-bootstrap.kafka.svc.cluster.local:9092"
    region          = var.aws_region
  })
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-producer"
    Component = "Producer"
  })
}

# Consumer EC2 Instance
resource "aws_instance" "consumer" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = var.ec2_instance_type
  
  subnet_id                   = module.vpc.public_subnets[1]
  vpc_security_group_ids      = [aws_security_group.demo_sg.id]
  associate_public_ip_address = true
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  key_name            = aws_key_pair.demo.key_name
  
  user_data = templatefile("${path.module}/userdata/consumer_setup.sh", {
    kafka_bootstrap     = "${module.eks.cluster_name}-kafka-bootstrap.kafka.svc.cluster.local:9092"
    s3_data_bucket      = aws_s3_bucket.data_bucket.id
    s3_dlq_bucket       = aws_s3_bucket.dlq_bucket.id
    redshift_endpoint   = aws_redshiftserverless_workgroup.main.endpoint[0].address
    redshift_database   = var.redshift_database_name
    redshift_username   = var.redshift_master_username
    redshift_password   = var.redshift_master_password
    region             = var.aws_region
  })
  
  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-consumer"
    Component = "Consumer"
  })
}

# Deploy Kafka using Strimzi
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
    
    labels = {
      name = "kafka"
      project = "oracle-cdc-pipeline"
    }
  }
}

resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  namespace  = kubernetes_namespace.kafka.metadata[0].name
  version    = "0.38.0"
  
  wait = true
}

# Outputs
output "oracle_endpoint" {
  value = aws_db_instance.oracle.endpoint
  description = "Oracle RDS endpoint"
}

output "producer_instance_ip" {
  value = aws_instance.producer.public_ip
  description = "Producer EC2 public IP"
}

output "consumer_instance_ip" {
  value = aws_instance.consumer.public_ip
  description = "Consumer EC2 public IP"
}

output "s3_data_bucket" {
  value = aws_s3_bucket.data_bucket.id
  description = "S3 data bucket name"
}

output "s3_dlq_bucket" {
  value = aws_s3_bucket.dlq_bucket.id
  description = "S3 DLQ bucket name"
}

output "redshift_endpoint" {
  value = aws_redshiftserverless_workgroup.main.endpoint[0].address
  description = "Redshift endpoint"
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
  description = "EKS cluster name"
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Command to configure kubectl"
}