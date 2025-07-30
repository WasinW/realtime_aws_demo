#!/bin/bash
set -e

# Update system
yum update -y
yum install -y python3 python3-pip git wget unzip

# Install Oracle Instant Client
cd /opt
wget https://download.oracle.com/otn_software/linux/instantclient/219000/instantclient-basic-linux.x64-21.9.0.0.0dbru.zip
unzip instantclient-basic-linux.x64-21.9.0.0.0dbru.zip
echo "/opt/instantclient_21_9" > /etc/ld.so.conf.d/oracle-instantclient.conf
ldconfig

# Set environment variables
cat >> /etc/environment <<EOF
ORACLE_ENDPOINT=${oracle_endpoint}
ORACLE_USERNAME=${oracle_username}
ORACLE_PASSWORD=${oracle_password}
KAFKA_BROKERS=${kafka_brokers}
AWS_REGION=${region}
LD_LIBRARY_PATH=/opt/instantclient_21_9:$LD_LIBRARY_PATH
EOF

# Create application directory
mkdir -p /opt/cdc-producer
cd /opt/cdc-producer

# Create placeholder for application code
cat > /opt/cdc-producer/wait_for_code.sh <<'EOF'
#!/bin/bash
echo "EC2 instance ready. Please deploy the producer application code."
echo "Oracle Endpoint: ${oracle_endpoint}"
echo "Kafka Brokers: ${kafka_brokers}"
EOF
chmod +x /opt/cdc-producer/wait_for_code.sh

# Create systemd service placeholder
cat > /etc/systemd/system/cdc-producer.service <<EOF
[Unit]
Description=CDC Producer Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/cdc-producer
ExecStart=/usr/bin/python3 /opt/cdc-producer/producer.py
Restart=always
EnvironmentFile=/etc/environment

[Install]
WantedBy=multi-user.target
EOF

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm