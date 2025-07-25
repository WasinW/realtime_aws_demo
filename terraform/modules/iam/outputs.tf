# terraform/modules/iam/outputs.tf
output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster role"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_group_role_arn" {
  description = "ARN of the EKS node group role"
  value       = aws_iam_role.eks_node_group.arn
}

output "msk_access_role_arn" {
  description = "ARN of the MSK access role"
  value       = aws_iam_role.msk_access.arn
}

output "redshift_msk_role_arn" {
  description = "ARN of the Redshift MSK role"
  value       = aws_iam_role.redshift_msk.arn
}

output "s3_backup_policy_arn" {
  description = "ARN of the S3 backup policy"
  value       = aws_iam_policy.s3_backup.arn
}