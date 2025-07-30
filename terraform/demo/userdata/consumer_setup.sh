#!/bin/bash
set -e

# Update system
yum update -y
yum install -y python3 python3-pip git postgresql

# Set environment variables
cat >> /etc/environment <<EOF
KAFKA_BROKERS=${kafka_brokers}
S3_BUCKET=${s3_bucket}
DLQ_BUCKET=${dlq_bucket}
REDSHIFT_ENDPOINT=${redshift_endpoint}
REDSHIFT_DATABASE=${redshift_database}
REDSHIFT_USERNAME=${redshift_username}
REDSHIFT_PASSWORD=${redshift_password}
REDSHIFT_ROLE_ARN=${redshift_role_arn}
AWS_REGION=${region}
EOF

# Create application directory
mkdir -p /opt/cdc-consumer
cd /opt/cdc-consumer

# Create placeholder for application code
cat > /opt/cdc-consumer/wait_for_code.sh <<'EOF'
#!/bin/bash
echo "EC2 instance ready. Please deploy the consumer application code."
echo "Kafka Brokers: ${kafka_brokers}"
echo "S3 Bucket: ${s3_bucket}"
echo "Redshift Endpoint: ${redshift_endpoint}"
EOF
chmod +x /opt/cdc-consumer/wait_for_code.sh

# Create systemd service placeholder
cat > /etc/systemd/system/cdc-consumer.service <<EOF
[Unit]
Description=CDC Consumer Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/cdc-consumer
ExecStart=/usr/bin/python3 /opt/cdc-consumer/consumer.py
Restart=always
EnvironmentFile=/etc/environment

[Install]
WantedBy=multi-user.target
EOF