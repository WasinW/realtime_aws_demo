output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "redshift_endpoint" {
  value = module.redshift.endpoint
}

output "kubectl_config_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_id}"
}

output "s3_bucket" {
  value = aws_s3_bucket.data.id
}

# เพิ่ม outputs ที่หาย
output "rds_master_password_secret_arn" {
  value = module.rds.master_password_secret_arn
}

output "redshift_master_password_secret_arn" {
  value = module.redshift.master_password_secret_arn
}