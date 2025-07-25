#!/bin/bash
# scripts/setup/05-create-secrets.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"

echo "Creating Kubernetes secrets..."

cd ${PROJECT_ROOT}/terraform/environments/demo

# Get RDS credentials from Secrets Manager
RDS_SECRET_ARN=$(terraform output -raw rds_master_password_secret_arn)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)

# Get secret value
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ${RDS_SECRET_ARN} --query SecretString --output text)
DB_USERNAME=$(echo ${SECRET_JSON} | jq -r .username)
DB_PASSWORD=$(echo ${SECRET_JSON} | jq -r .password)

# Create Oracle connection secret
kubectl create secret generic oracle-credentials \
    --from-literal=username=${DB_USERNAME} \
    --from-literal=password=${DB_PASSWORD} \
    --from-literal=endpoint=${RDS_ENDPOINT} \
    -n kafka || true

# Create Debezium user secret
kubectl create secret generic debezium-credentials \
    --from-literal=username=debezium \
    --from-literal=password='D3b3z1um#2024' \
    -n kafka || true

echo "Secrets created successfully!"

