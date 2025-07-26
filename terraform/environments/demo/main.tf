# ในส่วน Redshift module ให้ลบ/comment out MSK references
module "redshift" {
  source = "../../modules/redshift"
  
  name_prefix         = local.name_prefix
  vpc_id              = module.networking.vpc_id
  vpc_cidr            = var.vpc_cidr
  subnet_ids          = module.networking.private_subnet_ids
  node_type           = var.redshift_node_type
  node_count          = var.redshift_node_count
  # msk_cluster_arn     = module.msk.cluster_arn  # COMMENT OUT
  # msk_access_role_arn = module.iam.redshift_msk_role_arn  # COMMENT OUT
  msk_cluster_arn     = ""  # Empty for now
  msk_access_role_arn = ""  # Empty for now
  tags               = local.common_tags
}
