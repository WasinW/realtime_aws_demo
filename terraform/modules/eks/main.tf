# terraform/modules/eks/main.tf

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.name_prefix}-eks"
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # Make encryption optional
  dynamic "encryption_config" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      provider {
        key_arn = var.kms_key_arn
      }
      resources = ["secrets"]
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = var.tags
}

# OIDC Provider for EKS
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# EKS Node Groups
resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = each.key
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  update_config {
    max_unavailable = 1
  }

  instance_types = each.value.instance_types

  labels = merge(
    {
      "node-group" = each.key
    },
    each.value.labels
  )

  dynamic "taint" {
    for_each = lookup(each.value, "taints", [])
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-eks-${each.key}"
    }
  )

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# # Security Group for Pods
# resource "aws_security_group" "pod_sg" {
#   name_prefix = "${var.name_prefix}-eks-pod-"
#   vpc_id      = var.vpc_id

#   ingress {
#     from_port = 0
#     to_port   = 0
#     protocol  = "-1"
#     self      = true
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = merge(
#     var.tags,
#     {
#       Name = "${var.name_prefix}-eks-pod-sg"
#     }
#   )
# }

# # AWS Load Balancer Controller
# resource "helm_release" "aws_load_balancer_controller" {
#   name       = "aws-load-balancer-controller"
#   repository = "https://aws.github.io/eks-charts"
#   chart      = "aws-load-balancer-controller"
#   namespace  = "kube-system"
#   version    = "1.7.1"

#   set {
#     name  = "clusterName"
#     value = aws_eks_cluster.main.name
#   }

#   set {
#     name  = "serviceAccount.create"
#     value = "true"
#   }

#   set {
#     name  = "serviceAccount.name"
#     value = "aws-load-balancer-controller"
#   }

#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = aws_iam_role.aws_load_balancer_controller.arn
#   }

#   depends_on = [
#     aws_eks_node_group.main
#   ]
# }

# # IAM Role for AWS Load Balancer Controller
# resource "aws_iam_role" "aws_load_balancer_controller" {
#   name = "${var.name_prefix}-aws-load-balancer-controller"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Principal = {
#           Federated = aws_iam_openid_connect_provider.eks.arn
#         }
#         Action = "sts:AssumeRoleWithWebIdentity"
#         Condition = {
#           StringEquals = {
#             "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
#             "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
#           }
#         }
#       }
#     ]
#   })

#   tags = var.tags
# }

# # AWS Load Balancer Controller Policy
# resource "aws_iam_policy" "aws_load_balancer_controller" {
#   name        = "${var.name_prefix}-AWSLoadBalancerControllerIAMPolicy"
#   description = "IAM policy for AWS Load Balancer Controller"
#   policy      = file("${path.module}/policies/load-balancer-controller-policy.json")
# }

# resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
#   policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
#   role       = aws_iam_role.aws_load_balancer_controller.name
# }

# # EBS CSI Driver
# resource "aws_eks_addon" "ebs_csi_driver" {
#   cluster_name             = aws_eks_cluster.main.name
#   addon_name               = "aws-ebs-csi-driver"
#   addon_version            = "v1.28.0-eksbuild.1"
#   service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

#   tags = var.tags
# }

# # IAM Role for EBS CSI Driver
# resource "aws_iam_role" "ebs_csi_driver" {
#   name = "${var.name_prefix}-ebs-csi-driver"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Principal = {
#           Federated = aws_iam_openid_connect_provider.eks.arn
#         }
#         Action = "sts:AssumeRoleWithWebIdentity"
#         Condition = {
#           StringEquals = {
#             "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
#             "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
#           }
#         }
#       }
#     ]
#   })

#   tags = var.tags
# }

# resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
#   role       = aws_iam_role.ebs_csi_driver.name
# }
