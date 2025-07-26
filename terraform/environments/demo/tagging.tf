# terraform/environments/demo/tagging.tf - Centralized tagging configuration

# ========== TAGGING STRATEGY ==========
# 1. Provider default_tags - Applied to ALL resources automatically
# 2. Module tags - Passed to each module
# 3. Resource-specific tags - Merged for individual resources

locals {
  # Base tags ที่ทุก resource ต้องมี
  mandatory_tags = {
    Project     = var.project_name     # "oracle-cdc-pipeline"
    Environment = var.environment      # "demo"
    ManagedBy   = "terraform"
    CostCenter  = var.tags["CostCenter"]
    Owner       = var.tags["Owner"]
  }
  
  # Additional tags for tracking
  tracking_tags = {
    Terraform    = "true"
    DeployedAt   = timestamp()
    DeployedBy   = data.aws_caller_identity.current.user_id
    Region       = var.region
    ResourceGroup = var.project_name
  }
  
  # Merge all tags
  common_tags = merge(
    local.mandatory_tags,
    local.tracking_tags,
    var.additional_tags
  )
}

# ========== TAG COMPLIANCE CHECK ==========
# Data source to validate existing resources have proper tags
data "aws_resourcegroupstaggingapi_resources" "untagged" {
  # Find resources WITHOUT our project tag
  tag_filter {
    key    = "Project"
    values = ["!${var.project_name}"]  # NOT operator
  }
  
  # Only in our VPC
  resource_type_filters = [
    "ec2:instance",
    "ec2:security-group",
    "ec2:subnet",
    "ec2:vpc"
  ]
}

# ========== TAG POLICY DOCUMENT ==========
resource "aws_organizations_policy" "tagging_policy" {
  count = var.create_tag_policy ? 1 : 0
  
  name        = "${var.project_name}-tagging-policy"
  description = "Enforce tagging for CDC pipeline resources"
  type        = "TAG_POLICY"
  
  content = jsonencode({
    tags = {
      Project = {
        tag_key = {
          "@@assign" = "Project"
        }
        tag_value = {
          "@@assign" = [var.project_name]
        }
        enforced_for = {
          "@@assign" = [
            "ec2:*",
            "s3:*",
            "rds:*",
            "redshift:*",
            "kafka:*"
          ]
        }
      }
      Environment = {
        tag_key = {
          "@@assign" = "Environment"
        }
        tag_value = {
          "@@assign" = ["dev", "demo", "prod"]
        }
      }
    }
  })
}

# ========== MODULE EXAMPLE WITH FULL TAGGING ==========
module "networking" {
  source = "../../modules/networking"
  
  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  
  # Pass all common tags to module
  tags = local.common_tags
}

# ========== RESOURCE EXAMPLE WITH TAGS ==========
resource "aws_s3_bucket" "data" {
  bucket = "${local.name_prefix}-data"
  
  # Merge common tags with resource-specific tags
  tags = merge(
    local.common_tags,
    {
      Name        = "${local.name_prefix}-data-bucket"
      Type        = "data-storage"
      Encryption  = "AES256"
      Purpose     = "CDC data storage"
    }
  )
}

# ========== TAG VALIDATION OUTPUT ==========
output "tagging_report" {
  description = "Report of all tags applied"
  value = {
    mandatory_tags  = local.mandatory_tags
    common_tags     = local.common_tags
    untagged_count  = length(data.aws_resourcegroupstaggingapi_resources.untagged.resource_tag_mapping_list)
    
    # Sample resource tags (to verify)
    sample_tags = {
      s3_bucket = try(aws_s3_bucket.data.tags_all, {})
      vpc       = try(module.networking.vpc_tags, {})
      eks       = try(module.eks[0].cluster_tags, {})
    }
  }
}

# ========== AUTOMATIC TAG ENFORCEMENT ==========
resource "null_resource" "tag_validation" {
  # This runs after all resources are created
  depends_on = [
    module.networking,
    module.eks,
    module.rds,
    module.redshift
  ]
  
  provisioner "local-exec" {
    command = "bash ${path.module}/verify-tags.sh"
  }
}

# ========== RESOURCE GROUP FOR MONITORING ==========
resource "aws_resourcegroups_group" "project" {
  name = "${var.project_name}-resources"
  
  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = "Project"
          Values = [var.project_name]
        }
      ]
    })
  }
  
  tags = local.common_tags
}