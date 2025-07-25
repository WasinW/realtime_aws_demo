# terraform/modules/redshift/outputs.tf
output "cluster_identifier" {
  description = "The Redshift cluster identifier"
  value       = aws_redshift_cluster.main.cluster_identifier
}

output "endpoint" {
  description = "The Redshift cluster endpoint"
  value       = aws_redshift_cluster.main.endpoint
}

output "database_name" {
  description = "The name of the default database"
  value       = aws_redshift_cluster.main.database_name
}

output "master_username" {
  description = "The master username"
  value       = aws_redshift_cluster.main.master_username
}

output "master_password_secret_arn" {
  description = "ARN of the secret containing master password"
  value       = aws_secretsmanager_secret.redshift_master.arn
}

output "iam_role_arn" {
  description = "ARN of the Redshift IAM role"
  value       = aws_iam_role.redshift.arn
}