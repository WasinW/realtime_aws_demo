# terraform/modules/msk/main.tf

# MSK Configuration
resource "aws_msk_configuration" "main" {
  name = "${var.name_prefix}-msk-config"

  server_properties = <<PROPERTIES
auto.create.topics.enable=true
compression.type=lz4
delete.topic.enable=true
log.retention.hours=168
log.segment.bytes=1073741824
num.partitions=3
num.replica.fetchers=2
replica.lag.time.max.ms=30000
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
socket.send.buffer.bytes=102400
unclean.leader.election.enable=true
zookeeper.session.timeout.ms=18000
num.network.threads=8
num.io.threads=8
min.insync.replicas=2
default.replication.factor=3
PROPERTIES

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for MSK
resource "aws_security_group" "msk" {
  name_prefix = "${var.name_prefix}-msk-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka plaintext"
  }

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka TLS"
  }

  ingress {
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka IAM"
  }

  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Zookeeper"
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
      Name = "${var.name_prefix}-msk-sg"
    }
  )
}

# CloudWatch Log Group for MSK
resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.name_prefix}"
  retention_in_days = 7

  tags = var.tags
}

# S3 Bucket for MSK Logs
resource "aws_s3_bucket" "msk_logs" {
  bucket = "${var.name_prefix}-msk-${data.aws_caller_identity.current.account_id}"

  tags = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {} # Apply to all objects
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# MSK Cluster
resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.name_prefix}-msk"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type   = var.instance_type
    client_subnets  = var.subnet_ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.ebs_volume_size
        # provisioned_throughput {
        #   enabled           = var.enable_provisioned_throughput
        #   volume_throughput = var.provisioned_throughput
        # }
        dynamic "provisioned_throughput" {
          for_each = var.enable_provisioned_throughput ? [1] : []
          content {
            enabled           = true
            volume_throughput = var.provisioned_throughput
          }
        }
      }
    }
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_key_arn
    
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
      
      s3 {
        enabled = true
        bucket  = aws_s3_bucket.msk_logs.id
        prefix  = "broker-logs"
      }
    }
  }

  tags = var.tags
}

# Create initial topics
# resource "null_resource" "create_topics" {
#   depends_on = [aws_msk_cluster.main]

#   provisioner "local-exec" {
#     interpreter = ["PowerShell", "-Command"]
#     command = <<-EOF
#       # Wait for cluster to be ready
#       aws kafka describe-cluster --cluster-arn ${aws_msk_cluster.main.arn} --query 'ClusterInfo.State' --output text
      
#       # Get bootstrap servers
#       BOOTSTRAP_SERVERS=$(aws kafka get-bootstrap-brokers --cluster-arn ${aws_msk_cluster.main.arn} --query 'BootstrapBrokerStringTls' --output text)
      
#       # Create topics using kafka-topics.sh
#       for topic in ${join(" ", var.initial_topics)}; do
#         echo "Creating topic: $topic"
#         kafka-topics.sh --create \
#           --bootstrap-server $BOOTSTRAP_SERVERS \
#           --topic $topic \
#           --partitions ${var.default_partitions} \
#           --replication-factor ${var.default_replication_factor} \
#           --command-config /tmp/kafka-client.properties || true
#       done
#     EOF
#   }
# }

# Data source for current AWS account
data "aws_caller_identity" "current" {}
