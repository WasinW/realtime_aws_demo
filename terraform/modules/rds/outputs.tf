# terraform/modules/rds/outputs.tf
output "endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.oracle.endpoint
}

output "address" {
  description = "RDS instance address"
  value       = aws_db_instance.oracle.address
}

output "port" {
  description = "RDS instance port"
  value       = aws_db_instance.oracle.port
}

output "master_username" {
  description = "RDS master username"
  value       = aws_db_instance.oracle.username
}

output "master_password_secret_arn" {
  description = "ARN of the secret containing master password"
  value       = aws_secretsmanager_secret.rds_master.arn
}

output "security_group_id" {
  description = "Security group ID for RDS"
  value       = aws_security_group.rds.id
}