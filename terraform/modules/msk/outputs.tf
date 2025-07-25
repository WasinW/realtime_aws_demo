# terraform/modules/msk/outputs.tf
output "cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.main.arn
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "bootstrap_brokers_iam" {
  description = "IAM bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}

output "zookeeper_connect_string" {
  description = "Zookeeper connection string"
  value       = aws_msk_cluster.main.zookeeper_connect_string
}

output "security_group_id" {
  description = "Security group ID for MSK"
  value       = aws_security_group.msk.id
}