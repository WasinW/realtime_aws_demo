# Check existing resources
data "aws_resourcegroupstaggingapi_resources" "existing" {
  tag_filter {
    key    = "Project"
    values = [var.project_name]
  }
}

locals {
  existing_resources = {
    for r in data.aws_resourcegroupstaggingapi_resources.existing.resource_tag_mapping_list :
    r.resource_arn => r.tags
  }
}