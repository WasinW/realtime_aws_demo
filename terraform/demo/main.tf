terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

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

# Local variables for common tags
locals {
  common_tags = {
    Project     = "oracle-cdc-pipeline"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner_email
    CostCenter  = var.cost_center
    CreatedDate = formatdate("YYYY-MM-DD", timestamp())
  }
  
  name_prefix = "oracle-cdc-pipeline"
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

# Random suffix for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# VPC for EKS
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  
  name = "${local.name_prefix}-vpc"
  cidr = "10.0.0.0/16"
  
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  
  enable_nat_gateway   = true
  single_nat_gateway   = true
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

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"
  
  cluster_name    = "${local.name_prefix}-eks"
  cluster_version = "1.27"
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  
  # EKS Managed Node Group
  eks_managed_node_groups = {
    main = {
      desired_size = 3
      min_size     = 2
      max_size     = 5
      
      instance_types = ["t3.large"]
      
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
      
      tags = merge(local.common_tags, {
        Name = "${local.name_prefix}-eks-node"
        Type = "EKS-NodeGroup"
      })
    }
  }
  
  # Enable IRSA
  enable_irsa = true
  
  # Add-ons
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

# Configure Kubernetes Provider using module outputs
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

# Configure Helm Provider using module outputs
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
    Name        = "${local.name_prefix}-data"
    Purpose     = "CDC Data Storage"
    DataType    = "Parquet"
  })
}

resource "aws_s3_bucket" "dlq_bucket" {
  bucket = "${local.name_prefix}-dlq-${random_string.suffix.result}"
  
  tags = merge(local.common_tags, {
    Name        = "${local.name_prefix}-dlq"
    Purpose     = "Dead Letter Queue"
    DataType    = "JSON"
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

# S3 Bucket Lifecycle Configuration
resource "aws_s3_bucket_lifecycle_configuration" "data_bucket" {
  bucket = aws_s3_bucket.data_bucket.id
  
  rule {
    id     = "archive-old-data"
    status = "Enabled"
    
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    
    expiration {
      days = 365
    }
  }
}

# Oracle RDS Instance
resource "aws_db_instance" "oracle" {
  identifier     = "${local.name_prefix}-oracle"
  engine         = "oracle-ee"
  engine_version = "19.0.0.0.ru-2023-10.rur-2023-10.r1"
  
  instance_class         = var.oracle_instance_class
  allocated_storage      = var.oracle_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = false
  
  db_name  = "CRMDB"
  username = var.oracle_master_username
  password = var.oracle_master_password
  
  publicly_accessible = true
  skip_final_snapshot = true
  deletion_protection = false
  
  enabled_cloudwatch_logs_exports = ["alert", "trace"]
  
  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-oracle"
    Type     = "RDS-Oracle"
    Purpose  = "Source Database"
  })
}

# Redshift Serverless
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${local.name_prefix}-namespace"
  db_name            = "crmanalytics"
  admin_username     = var.redshift_master_username
  admin_user_password = var.redshift_master_password
  
  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-redshift-namespace"
    Type    = "Redshift-Serverless"
    Purpose = "Analytics Database"
  })
}

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${local.name_prefix}-workgroup"
  
  base_capacity      = 32
  publicly_accessible = true
  
  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-redshift-workgroup"
    Type    = "Redshift-Serverless"
    Purpose = "Analytics Workgroup"
  })
}

# IAM Role for Redshift
resource "aws_iam_role" "redshift_role" {
  name = "${local.name_prefix}-redshift-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
      }
    ]
  })
  
  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-redshift-role"
    Type    = "IAM-Role"
    Purpose = "Redshift S3 Access"
  })
}

resource "aws_iam_role_policy" "redshift_s3_policy" {
  name = "${local.name_prefix}-redshift-s3-policy"
  role = aws_iam_role.redshift_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_bucket.arn,
          "${aws_s3_bucket.data_bucket.arn}/*"
        ]
      }
    ]
  })
}

# CloudWatch Log Group for RDS
resource "aws_cloudwatch_log_group" "oracle_logs" {
  name              = "/aws/rds/instance/${local.name_prefix}-oracle/alert"
  retention_in_days = 7
  
  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-oracle-logs"
    Type    = "CloudWatch-Logs"
    Purpose = "Oracle Alert Logs"
  })
}

# ECR Repository
resource "aws_ecr_repository" "cdc_apps" {
  name = local.name_prefix
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = merge(local.common_tags, {
    Name    = local.name_prefix
    Type    = "ECR"
    Purpose = "Container Registry"
  })
}

# Deploy Kafka using Helm
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
    
    labels = {
      name        = "kafka"
      project     = "oracle-cdc-pipeline"
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

resource "helm_release" "kafka" {
  name       = "kafka"
  namespace  = kubernetes_namespace.kafka.metadata[0].name
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = "0.38.0"
  
  wait = true
}

# Wait for Strimzi operator to be ready
resource "time_sleep" "wait_for_strimzi" {
  depends_on = [helm_release.kafka]
  
  create_duration = "60s"
}

# Deploy Kafka cluster using Strimzi
resource "kubernetes_manifest" "kafka_cluster" {
  depends_on = [time_sleep.wait_for_strimzi]
  
  manifest = {
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name      = "cdc-cluster"
      namespace = kubernetes_namespace.kafka.metadata[0].name
      labels = {
        project     = "oracle-cdc-pipeline"
        environment = var.environment
        managed-by  = "terraform"
      }
    }
    spec = {
      kafka = {
        version  = "3.5.1"
        replicas = 3
        
        listeners = [
          {
            name = "plain"
            port = 9092
            type = "internal"
            tls  = false
          },
          {
            name = "external"
            port = 9094
            type = "loadbalancer"
            tls  = false
          }
        ]
        
        config = {
          "offsets.topic.replication.factor"         = 3
          "transaction.state.log.replication.factor" = 3
          "transaction.state.log.min.isr"           = 2
          "default.replication.factor"              = 3
          "min.insync.replicas"                     = 2
          "inter.broker.protocol.version"           = "3.5"
          "auto.create.topics.enable"               = true
          "num.partitions"                          = 10
        }
        
        storage = {
          type = "persistent-claim"
          size = "100Gi"
          class = "gp2"
        }
        
        template = {
          pod = {
            metadata = {
              labels = {
                project     = "oracle-cdc-pipeline"
                environment = var.environment
              }
            }
          }
        }
      }
      
      zookeeper = {
        replicas = 3
        
        storage = {
          type = "persistent-claim"
          size = "10Gi"
          class = "gp2"
        }
        
        template = {
          pod = {
            metadata = {
              labels = {
                project     = "oracle-cdc-pipeline"
                environment = var.environment
              }
            }
          }
        }
      }
      
      entityOperator = {
        topicOperator = {}
        userOperator  = {}
      }
    }
  }
}

# Deploy Kafka UI
resource "helm_release" "kafka_ui" {
  depends_on = [kubernetes_manifest.kafka_cluster]
  
  name       = "kafka-ui"
  namespace  = kubernetes_namespace.kafka.metadata[0].name
  repository = "https://provectus.github.io/kafka-ui"
  chart      = "kafka-ui"
  version    = "0.7.5"
  
  values = [
    yamlencode({
      yamlApplicationConfig = {
        kafka = {
          clusters = [
            {
              name           = "cdc-cluster"
              bootstrapServers = "cdc-cluster-kafka-bootstrap:9092"
              zookeeper      = "cdc-cluster-zookeeper-client:2181"
            }
          ]
        }
        auth = {
          type = "disabled"
        }
        management = {
          health = {
            ldap = {
              enabled = false
            }
          }
        }
      }
      
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags" = "Project=oracle-cdc-pipeline,Environment=${var.environment}"
        }
      }
      
      podLabels = {
        project     = "oracle-cdc-pipeline"
        environment = var.environment
        component   = "kafka-ui"
      }
    })
  ]
}

# Deploy CDC applications namespace
resource "kubernetes_namespace" "cdc_apps" {
  metadata {
    name = "cdc-apps"
    
    labels = {
      name        = "cdc-apps"
      project     = "oracle-cdc-pipeline"
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

# IAM Role for Consumer Service Account (IRSA)
resource "aws_iam_role" "consumer_irsa" {
  name = "${local.name_prefix}-consumer-irsa"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:cdc-apps:cdc-consumer"
            "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
  
  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-consumer-irsa"
    Type    = "IAM-Role"
    Purpose = "Consumer Service Account"
  })
}

resource "aws_iam_role_policy" "consumer_s3_policy" {
  name = "${local.name_prefix}-consumer-s3-policy"
  role = aws_iam_role.consumer_irsa.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_bucket.arn,
          "${aws_s3_bucket.data_bucket.arn}/*",
          aws_s3_bucket.dlq_bucket.arn,
          "${aws_s3_bucket.dlq_bucket.arn}/*"
        ]
      }
    ]
  })
}

# Outputs
output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint for EKS control plane"
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "oracle_endpoint" {
  value       = aws_db_instance.oracle.endpoint
  description = "Oracle RDS endpoint"
}

output "kafka_namespace" {
  value       = kubernetes_namespace.kafka.metadata[0].name
  description = "Kafka namespace"
}

output "s3_data_bucket" {
  value       = aws_s3_bucket.data_bucket.id
  description = "S3 data bucket name"
}

output "s3_dlq_bucket" {
  value       = aws_s3_bucket.dlq_bucket.id
  description = "S3 DLQ bucket name"
}

output "redshift_endpoint" {
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].address
  description = "Redshift endpoint"
}

output "redshift_role_arn" {
  value       = aws_iam_role.redshift_role.arn
  description = "Redshift IAM role ARN"
}

output "consumer_irsa_arn" {
  value       = aws_iam_role.consumer_irsa.arn
  description = "Consumer IRSA role ARN"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.cdc_apps.repository_url
  description = "ECR repository URL"
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Command to configure kubectl"
}

output "project_tags" {
  value       = local.common_tags
  description = "Common tags applied to all resources"
}