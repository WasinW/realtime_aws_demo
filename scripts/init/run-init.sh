#!/bin/bash
# Master initialization script

set -e

echo "🚀 Starting CDC Demo Initialization"

# 1. Deploy Infrastructure
echo "1. Deploying infrastructure..."
cd terraform/environments/demo
terraform init
terraform apply -auto-approve
cd ../../..

# 2. Configure kubectl
echo "2. Configuring kubectl..."
aws eks update-kubeconfig --region ap-southeast-1 --name oracle-cdc-pipeline-demo-eks

# 3. Install Strimzi
echo "3. Installing Strimzi operator..."
kubectl create namespace kafka || true
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# 4. Deploy Kafka cluster
echo "4. Deploying Kafka cluster..."
kubectl apply -f kubernetes/kafka/01-kafka-cluster.yaml

# 5. Wait for Kafka
echo "5. Waiting for Kafka to be ready..."
kubectl wait --for=condition=ready kafka/demo-kafka-cluster -n kafka --timeout=600s

# 6. Create topics
echo "6. Creating Kafka topics..."
bash scripts/init/03-create-topics.sh

# 7. Initialize Oracle database
echo "7. Initializing Oracle database..."
RDS_ENDPOINT=$(cd terraform/environments/demo && terraform output -raw rds_endpoint)
echo "Please run scripts/init/01-init-oracle-db.sql on Oracle at: $RDS_ENDPOINT"

# 8. Initialize Redshift
echo "8. Initializing Redshift..."
REDSHIFT_ENDPOINT=$(cd terraform/environments/demo && terraform output -raw redshift_endpoint)
echo "Please run scripts/init/02-init-redshift.sql on Redshift at: $REDSHIFT_ENDPOINT"

# 9. Deploy Debezium
echo "9. Deploying Debezium connector..."
kubectl apply -f kubernetes/debezium/

echo "✅ Initialization complete!"