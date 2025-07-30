#!/bin/bash
set -e

# Update system
yum update -y
yum install -y python3 python3-pip git wget java-11-openjdk-devel postgresql

# Install Kafka client
cd /opt
wget https://downloads.apache.org/kafka/3.5.1/kafka_2.13-3.5.1.tgz
tar -xzf kafka_2.13-3.5.1.tgz
ln -s kafka_2.13-3.5.1 kafka

# Set environment variables
cat >> /etc/environment <<EOF
KAFKA_BOOTSTRAP_SERVERS=${kafka_bootstrap}
S3_DATA_BUCKET=${s3_data_bucket}
S3_DLQ_BUCKET=${s3_dlq_bucket}
REDSHIFT_ENDPOINT=${redshift_endpoint}
REDSHIFT_DATABASE=${redshift_database}
REDSHIFT_USERNAME=${redshift_username}
REDSHIFT_PASSWORD=${redshift_password}
AWS_REGION=${region}
KAFKA_HOME=/opt/kafka
PATH=$PATH:/opt/kafka/bin
EOF

# Install Python dependencies
pip3 install kafka-python boto3 psycopg2-binary pyarrow pandas

# Create application directory
mkdir -p /opt/cdc-consumer
cd /opt/cdc-consumer

# Create systemd service for consumer
cat > /etc/systemd/system/cdc-consumer.service <<EOF
[Unit]
Description=CDC Consumer Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/cdc-consumer
EnvironmentFile=/etc/environment
ExecStart=/usr/bin/python3 /opt/cdc-consumer/consumer.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm