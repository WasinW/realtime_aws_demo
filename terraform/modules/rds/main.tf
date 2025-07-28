# terraform/modules/rds/main.tf

# Security Group for RDS
resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-oracle-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 1521
    to_port     = 1521
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Oracle database port"
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
      Name = "${var.name_prefix}-rds-oracle-sg"
    }
  )
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-oracle"
  subnet_ids = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-oracle-subnet-group"
    }
  )
}

# DB Parameter Group
resource "aws_db_parameter_group" "oracle" {
  name   = "${var.name_prefix}-oracle-params"
  family = "oracle-ee-19"

  parameter {
    name  = "enable_goldengate_replication"
    value = "true"
  }

  parameter {
    name  = "compatible"
    value = "19.0.0"
  }

  parameter {
    name  = "db_recovery_file_dest_size"
    value = "100"
  }

  tags = var.tags
}

# DB Option Group
resource "aws_db_option_group" "oracle" {
  name                     = "${var.name_prefix}-oracle-options"
  engine_name              = "oracle-ee"
  major_engine_version     = "19"

  # Enable supplemental logging for CDC
  option {
    option_name = "Timezone"
    option_settings {
      name  = "TIME_ZONE"
      value = "UTC"
    }
  }

  tags = var.tags
}

# KMS Key for RDS Encryption
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-rds-kms"
    }
  )
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# Random password for master user
# Random password for master user (Oracle max 30 chars)
resource "random_password" "master" {
  length  = 20
  special = true
  override_special = "!#$%*()-_=+[]{}<>:?"  # ไม่มี & และ @
}

# Store password in Secrets Manager
resource "aws_secretsmanager_secret" "rds_master" {
  name_prefix = "${var.name_prefix}-rds-oracle-master-"  # ใช้ name_prefix
  recovery_window_in_days = 0  # ลบได้ทันที
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.master.result
  })
}

# RDS Instance
resource "aws_db_instance" "oracle" {
  identifier = "${var.name_prefix}-oracle"

  # Engine
  engine         = "oracle-ee"
  engine_version = var.engine_version
  license_model  = "bring-your-own-license"

  # Instance
  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  # Database
  db_name  = "ORCLCDB"
  port     = 1521
  username = "admin"
  password = random_password.master.result

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Options
  parameter_group_name = aws_db_parameter_group.oracle.name
  option_group_name    = aws_db_option_group.oracle.name

  # Backup
  # backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  # Monitoring
  # enabled_cloudwatch_logs_exports = ["alert", "audit", "trace", "listener"]
  # performance_insights_enabled    = true
  performance_insights_retention_period = 7

  # Other
  # deletion_protection = false
  # skip_final_snapshot = true
  apply_immediately   = true

  # Demo optimizations
  backup_retention_period = var.backup_retention_period
  multi_az               = var.multi_az
  deletion_protection    = var.deletion_protection
  skip_final_snapshot    = true  # For easy cleanup
  
  # Reduce monitoring for cost
  enabled_cloudwatch_logs_exports = []  # No logs export for demo
  performance_insights_enabled    = false  # Disable for demo


  tags = var.tags
}

# Create Debezium user and enable CDC
# resource "null_resource" "setup_oracle_cdc" {
#   depends_on = [aws_db_instance.oracle]

#   provisioner "local-exec" {
#     command = <<-EOF
#       # Wait for RDS to be available
#       aws rds wait db-instance-available --db-instance-identifier ${aws_db_instance.oracle.identifier}
      
#       # Execute SQL commands to set up CDC
#       cat > /tmp/setup_cdc.sql <<SQL
#       -- Enable supplemental logging
#       ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
#       ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

#       -- Create tablespace for Debezium
#       CREATE TABLESPACE debezium_ts DATAFILE SIZE 100M AUTOEXTEND ON NEXT 10M;

#       -- Create Debezium user
#       CREATE USER debezium IDENTIFIED BY "D3b3z1um#2024" 
#         DEFAULT TABLESPACE debezium_ts
#         QUOTA UNLIMITED ON debezium_ts;

#       -- Grant necessary privileges
#       GRANT CREATE SESSION TO debezium;
#       GRANT SELECT ON V_\$DATABASE TO debezium;
#       GRANT SELECT ON V_\$LOG TO debezium;
#       GRANT SELECT ON V_\$LOGFILE TO debezium;
#       GRANT SELECT ON V_\$ARCHIVED_LOG TO debezium;
#       GRANT SELECT ON V_\$ARCHIVE_DEST_STATUS TO debezium;
#       GRANT SELECT ON V_\$TRANSACTION TO debezium;
#       GRANT SELECT ON DBA_REGISTRY TO debezium;
#       GRANT SELECT ANY TABLE TO debezium;
#       GRANT SELECT_CATALOG_ROLE TO debezium;
#       GRANT EXECUTE_CATALOG_ROLE TO debezium;
#       GRANT FLASHBACK ANY TABLE TO debezium;
#       GRANT LOGMINING TO debezium;

#       -- Create demo schema and tables
#       CREATE USER demo_user IDENTIFIED BY "Demo#2024"
#         DEFAULT TABLESPACE users
#         QUOTA UNLIMITED ON users;

#       GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO demo_user;

#       -- Connect as demo_user and create tables
#       ALTER SESSION SET CURRENT_SCHEMA = demo_user;

#       CREATE TABLE customers (
#         customer_id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
#         first_name VARCHAR2(100) NOT NULL,
#         last_name VARCHAR2(100) NOT NULL,
#         email VARCHAR2(200) UNIQUE NOT NULL,
#         phone VARCHAR2(20),
#         ssn VARCHAR2(20),
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
#       );

#       CREATE TABLE products (
#         product_id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
#         product_name VARCHAR2(200) NOT NULL,
#         category VARCHAR2(100),
#         price NUMBER(10,2) NOT NULL,
#         stock_quantity NUMBER DEFAULT 0,
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
#       );

#       CREATE TABLE orders (
#         order_id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
#         customer_id NUMBER NOT NULL,
#         order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         total_amount NUMBER(10,2),
#         status VARCHAR2(50) DEFAULT 'PENDING',
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
#       );

#       CREATE TABLE order_items (
#         order_item_id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
#         order_id NUMBER NOT NULL,
#         product_id NUMBER NOT NULL,
#         quantity NUMBER NOT NULL,
#         unit_price NUMBER(10,2) NOT NULL,
#         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
#         CONSTRAINT fk_order FOREIGN KEY (order_id) REFERENCES orders(order_id),
#         CONSTRAINT fk_product FOREIGN KEY (product_id) REFERENCES products(product_id)
#       );

#       -- Enable supplemental logging on tables
#       ALTER TABLE customers ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
#       ALTER TABLE products ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
#       ALTER TABLE orders ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
#       ALTER TABLE order_items ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

#       -- Grant access to Debezium
#       GRANT SELECT ON demo_user.customers TO debezium;
#       GRANT SELECT ON demo_user.products TO debezium;
#       GRANT SELECT ON demo_user.orders TO debezium;
#       GRANT SELECT ON demo_user.order_items TO debezium;
# SQL

#       # Execute the SQL file
#       # Note: In production, you would use proper Oracle client tools
#       echo "Oracle CDC setup complete"
#     EOF
#   }
# }
