# terraform/environments/demo/locals.tf

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  
  # Calculate subnet CIDR blocks dynamically
  private_subnet_cidrs = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnet_cidrs  = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
  
  # Common tags for all resources
  common_tags = merge(
    var.tags,
    {
      Terraform   = "true"
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "terraform"
      CostCenter  = var.tags["CostCenter"]
    }
  )
}