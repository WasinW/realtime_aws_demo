# terraform/modules/iam/main.tf

# EKS Service Role
resource "aws_iam_role" "eks_cluster" {
  name = "${var.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Node Group Role
resource "aws_iam_role" "eks_node_group" {
  name = "${var.name_prefix}-eks-node-group-role"

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

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# MSK Access Role for EKS Pods
resource "aws_iam_role" "msk_access" {
  name = "${var.name_prefix}-msk-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.eks_oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:kafka:debezium-connect"
            "${replace(var.eks_oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# MSK Access Policy
resource "aws_iam_policy" "msk_access" {
  name        = "${var.name_prefix}-msk-access-policy"
  description = "Policy for accessing MSK cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.name_prefix}-msk/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:*Topic*",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:topic/${var.name_prefix}-msk/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:group/${var.name_prefix}-msk/*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "msk_access" {
  policy_arn = aws_iam_policy.msk_access.arn
  role       = aws_iam_role.msk_access.name
}

# Redshift Role for MSK Access
resource "aws_iam_role" "redshift_msk" {
  name = "${var.name_prefix}-redshift-msk-role"

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

  tags = var.tags
}

resource "aws_iam_policy" "redshift_msk" {
  name        = "${var.name_prefix}-redshift-msk-policy"
  description = "Policy for Redshift to access MSK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:DescribeTopic"
        ]
        Resource = [
          "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.name_prefix}-msk/*",
          "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:topic/${var.name_prefix}-msk/*/*",
          "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:group/${var.name_prefix}-msk/*/*"
        ]
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "redshift_msk" {
  policy_arn = aws_iam_policy.redshift_msk.arn
  role       = aws_iam_role.redshift_msk.name
}

# S3 Access for Backups
resource "aws_iam_policy" "s3_backup" {
  name        = "${var.name_prefix}-s3-backup-policy"
  description = "Policy for accessing S3 backup bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-backups",
          "arn:aws:s3:::${var.name_prefix}-backups/*"
        ]
      }
    ]
  })

  tags = var.tags
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

