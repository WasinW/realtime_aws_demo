# terraform/modules/redshift/main.tf

# Security Group for Redshift
resource "aws_security_group" "redshift" {
  name_prefix = "${var.name_prefix}-redshift-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Redshift port"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-redshift-sg"
    }
  )
}

# Redshift Subnet Group
resource "aws_redshift_subnet_group" "main" {
  name       = "${var.name_prefix}-redshift"
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-redshift-subnet-group"
    }
  )
}

# Redshift Parameter Group
resource "aws_redshift_parameter_group" "main" {
  name   = "${var.name_prefix}-redshift-params"
  family = "redshift-1.0"

  parameter {
    name  = "enable_user_activity_logging"
    value = "true"
  }

  parameter {
    name  = "require_ssl"
    value = "true"
  }

  parameter {
    name  = "enable_case_sensitive_identifier"
    value = "true"
  }

  tags = var.tags
}

# Random password for master user
resource "random_password" "redshift_master" {
  length  = 32
  special = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Store password in Secrets Manager
resource "aws_secretsmanager_secret" "redshift_master" {
  name = "${var.name_prefix}-redshift-master-password"
  # name = "${var.name_prefix}-redshift-master-pwd-${formatdate("YYYYMMDD", timestamp())}"
  # name_prefix = "${var.name_prefix}-redshift-master-"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "redshift_master" {
  secret_id = aws_secretsmanager_secret.redshift_master.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.redshift_master.result
  })
}

# IAM Role for Redshift
resource "aws_iam_role" "redshift" {
  name = "${var.name_prefix}-redshift-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# S3 Read Policy for Redshift
resource "aws_iam_role_policy" "redshift_s3" {
  name = "${var.name_prefix}-redshift-s3-policy"
  role = aws_iam_role.redshift.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-data",
          "arn:aws:s3:::${var.name_prefix}-data/*"
        ]
      }
    ]
  })
}

# Attach Redshift Spectrum policy
resource "aws_iam_role_policy_attachment" "redshift_spectrum" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonRedshiftAllCommandsFullAccess"
  role       = aws_iam_role.redshift.name
}

# Redshift Cluster
resource "aws_redshift_cluster" "main" {
  cluster_identifier = "${var.name_prefix}-redshift"
  database_name      = "cdcdemo"
  master_username    = "admin"
  master_password    = random_password.redshift_master.result
  
  node_type       = var.node_type
  cluster_type    = var.node_count > 1 ? "multi-node" : "single-node"
  number_of_nodes = var.node_count
  
  cluster_subnet_group_name    = aws_redshift_subnet_group.main.name
  cluster_parameter_group_name = aws_redshift_parameter_group.main.name
  
  vpc_security_group_ids = [aws_security_group.redshift.id]
  # iam_roles              = [aws_iam_role.redshift.arn, var.msk_access_role_arn]
  iam_roles = compact([
    aws_iam_role.redshift.arn,
    var.msk_access_role_arn != "" ? var.msk_access_role_arn : null
  ])

  
  encrypted                    = true
  enhanced_vpc_routing         = true
  publicly_accessible          = false
  automated_snapshot_retention_period = 7
  
  skip_final_snapshot = true  # สำหรับ demo
  # logging {
  #   enable        = true
  #   bucket_name   = aws_s3_bucket.redshift_logs.id
  #   s3_key_prefix = "redshift-logs"
  # }
  
  tags = var.tags
}

# เพิ่มหลัง aws_redshift_cluster resource
resource "aws_redshift_logging" "main" {
  cluster_identifier = aws_redshift_cluster.main.id
  log_destination_type = "s3"
  bucket_name         = aws_s3_bucket.redshift_logs.id
  s3_key_prefix       = "redshift-logs"

  depends_on = [aws_s3_bucket_policy.redshift_logs]

}

# S3 Bucket for Redshift Logs
resource "aws_s3_bucket" "redshift_logs" {
  bucket = "${var.name_prefix}-rs-logs-${data.aws_caller_identity.current.account_id}"

  tags = var.tags
}

# เพิ่มหลัง resource "aws_s3_bucket" "redshift_logs"
resource "aws_s3_bucket_policy" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRedshiftLogs"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          aws_s3_bucket.redshift_logs.arn,
          "${aws_s3_bucket.redshift_logs.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {} # Apply to all objects
    
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redshift_logs" {
  bucket = aws_s3_bucket.redshift_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Create initial schema and tables
# resource "null_resource" "setup_redshift" {
#   depends_on = [aws_redshift_cluster.main]

#   provisioner "local-exec" {
#     command = <<-EOF
#       # Wait for Redshift to be available
#       aws redshift wait cluster-available --cluster-identifier ${aws_redshift_cluster.main.cluster_identifier}
      
#       # Create schema and tables SQL
#       cat > /tmp/setup_redshift.sql <<SQL
#       -- Create schemas
#       CREATE SCHEMA IF NOT EXISTS staging;
#       CREATE SCHEMA IF NOT EXISTS marts;
      
#       -- Create external schema for MSK streaming ingestion
#       CREATE EXTERNAL SCHEMA msk_streaming
#       FROM MSK
#       IAM_ROLE '${var.msk_access_role_arn}'
#       AUTHENTICATION iam
#       CLUSTER_ARN '${var.msk_cluster_arn}';
      
#       -- Create staging tables for CDC data
#       CREATE TABLE staging.customers_raw (
#         kafka_partition INTEGER,
#         kafka_offset BIGINT,
#         kafka_timestamp TIMESTAMP,
#         kafka_key VARCHAR(256),
#         kafka_value SUPER,
#         kafka_headers SUPER
#       );
      
#       CREATE TABLE staging.products_raw (
#         kafka_partition INTEGER,
#         kafka_offset BIGINT,
#         kafka_timestamp TIMESTAMP,
#         kafka_key VARCHAR(256),
#         kafka_value SUPER,
#         kafka_headers SUPER
#       );
      
#       CREATE TABLE staging.orders_raw (
#         kafka_partition INTEGER,
#         kafka_offset BIGINT,
#         kafka_timestamp TIMESTAMP,
#         kafka_key VARCHAR(256),
#         kafka_value SUPER,
#         kafka_headers SUPER
#       );
      
#       -- Create materialized views for streaming ingestion
#       CREATE MATERIALIZED VIEW staging.customers_stream AS
#       SELECT 
#         kafka_partition,
#         kafka_offset,
#         kafka_timestamp,
#         JSON_PARSE(kafka_value) as change_data
#       FROM msk_streaming."oracle.inventory.customers.masked"
#       AUTO REFRESH YES;
      
#       CREATE MATERIALIZED VIEW staging.products_stream AS
#       SELECT 
#         kafka_partition,
#         kafka_offset,
#         kafka_timestamp,
#         JSON_PARSE(kafka_value) as change_data
#       FROM msk_streaming."oracle.inventory.products.masked"
#       AUTO REFRESH YES;
      
#       CREATE MATERIALIZED VIEW staging.orders_stream AS
#       SELECT 
#         kafka_partition,
#         kafka_offset,
#         kafka_timestamp,
#         JSON_PARSE(kafka_value) as change_data
#       FROM msk_streaming."oracle.inventory.orders.masked"
#       AUTO REFRESH YES;
      
#       -- Create final dimension and fact tables
#       CREATE TABLE marts.dim_customers (
#         customer_id INTEGER PRIMARY KEY,
#         first_name VARCHAR(100),
#         last_name VARCHAR(100),
#         email VARCHAR(200),
#         phone VARCHAR(20),
#         ssn_token VARCHAR(100),
#         valid_from TIMESTAMP,
#         valid_to TIMESTAMP,
#         is_current BOOLEAN
#       )
#       DISTSTYLE KEY
#       DISTKEY (customer_id)
#       SORTKEY (customer_id, valid_from);
      
#       CREATE TABLE marts.dim_products (
#         product_id INTEGER PRIMARY KEY,
#         product_name VARCHAR(200),
#         category VARCHAR(100),
#         price DECIMAL(10,2),
#         stock_quantity INTEGER,
#         valid_from TIMESTAMP,
#         valid_to TIMESTAMP,
#         is_current BOOLEAN
#       )
#       DISTSTYLE ALL;
      
#       CREATE TABLE marts.fact_orders (
#         order_id INTEGER PRIMARY KEY,
#         customer_id INTEGER,
#         order_date TIMESTAMP,
#         total_amount DECIMAL(10,2),
#         status VARCHAR(50),
#         created_at TIMESTAMP,
#         updated_at TIMESTAMP
#       )
#       DISTSTYLE KEY
#       DISTKEY (customer_id)
#       SORTKEY (order_date);
      
#       -- Create stored procedures for CDC merge
#       CREATE OR REPLACE PROCEDURE staging.merge_customers()
#       AS $$
#       BEGIN
#         -- Update existing records (set valid_to and is_current = false)
#         UPDATE marts.dim_customers
#         SET valid_to = CURRENT_TIMESTAMP,
#             is_current = FALSE
#         FROM (
#           SELECT DISTINCT 
#             change_data.after.customer_id::INT as customer_id
#           FROM staging.customers_stream
#           WHERE change_data.op IN ('u', 'd')
#         ) updates
#         WHERE marts.dim_customers.customer_id = updates.customer_id
#           AND marts.dim_customers.is_current = TRUE;
        
#         -- Insert new records
#         INSERT INTO marts.dim_customers
#         SELECT 
#           change_data.after.customer_id::INT,
#           change_data.after.first_name::VARCHAR,
#           change_data.after.last_name::VARCHAR,
#           change_data.after.email::VARCHAR,
#           change_data.after.phone::VARCHAR,
#           change_data.after.ssn::VARCHAR,
#           kafka_timestamp,
#           NULL,
#           TRUE
#         FROM staging.customers_stream
#         WHERE change_data.op IN ('c', 'u', 'r');
#       END;
#       $$ LANGUAGE plpgsql;
      
#       -- Grant permissions
#       GRANT USAGE ON SCHEMA staging TO GROUP analysts;
#       GRANT USAGE ON SCHEMA marts TO GROUP analysts;
#       GRANT SELECT ON ALL TABLES IN SCHEMA marts TO GROUP analysts;
# SQL

#       echo "Redshift setup complete"
#     EOF
#   }
# }

# Data source for current AWS account
data "aws_caller_identity" "current" {}
