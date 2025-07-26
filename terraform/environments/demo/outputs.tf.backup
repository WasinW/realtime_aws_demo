# terraform/environments/demo/outputs.tf
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "msk_bootstrap_brokers_iam" {
  description = "MSK IAM bootstrap brokers"
  value       = module.msk.bootstrap_brokers_iam
}

output "rds_endpoint" {
  description = "RDS Oracle endpoint"
  value       = module.rds.endpoint
}

output "redshift_endpoint" {
  description = "Redshift cluster endpoint"
  value       = module.redshift.endpoint
}

output "s3_data_bucket" {
  description = "S3 data bucket name"
  value       = aws_s3_bucket.data.id
}

output "s3_backups_bucket" {
  description = "S3 backups bucket name"
  value       = aws_s3_bucket.backups.id
}

output "kubectl_config" {
  description = "kubectl configuration commands"
  value = <<-EOT
    aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_id}
  EOT
}

