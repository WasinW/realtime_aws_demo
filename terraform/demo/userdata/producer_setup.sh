#!/bin/bash
set -e

# Update system
yum update -y
yum install -y python3 python3-pip git wget unzip java-11-openjdk-devel

# Install Oracle Instant Client
cd /opt
wget https://download.oracle.com/otn_software/linux/instantclient/219000/instantclient-basic-linux.x64-21.9.0.0.0dbru.zip
unzip instantclient-basic-linux.x64-21.9.0.0.0dbru.zip
echo "/opt/instantclient_21_9" > /etc/ld.so.conf.d/oracle-instantclient.conf
ldconfig

# Install Kafka client
cd /opt
wget https://downloads.apache.org/kafka/3.5.1/kafka_2.13-3.5.1.tgz
tar -xzf kafka_2.13-3.5.1.tgz
ln -s kafka_2.13-3.5.1 kafka

# Set environment variables
cat >> /etc/environment <<EOF
ORACLE_ENDPOINT=${oracle_endpoint}
ORACLE_USERNAME=${oracle_username}
ORACLE_PASSWORD=${oracle_password}
KAFKA_BOOTSTRAP_SERVERS=${kafka_bootstrap}
AWS_REGION=${region}
LD_LIBRARY_PATH=/opt/instantclient_21_9:$LD_LIBRARY_PATH
KAFKA_HOME=/opt/kafka
PATH=$PATH:/opt/kafka/bin
EOF

# Install Python dependencies
pip3 install cx_Oracle kafka-python boto3 psycopg2-binary

# Create application directory
mkdir -p /opt/cdc-producer
cd /opt/cdc-producer

# Create systemd service for producer
cat > /etc/systemd/system/cdc-producer.service <<EOF
[Unit]
Description=CDC Producer Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/cdc-producer
EnvironmentFile=/etc/environment
ExecStart=/usr/bin/python3 /opt/cdc-producer/producer.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm