#!/bin/bash
# setup-all-accounts-fixed.sh

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-southeast-1"

echo "Setting up all service accounts and users..."

# 1. Create K8s Service Accounts (skip if exists)
kubectl create serviceaccount debezium-connect -n kafka 2>/dev/null || echo "SA debezium-connect already exists"
kubectl create serviceaccount pii-masking -n kafka 2>/dev/null || echo "SA pii-masking already exists"

# 2. Get database endpoints from Terraform
cd terraform/environments/demo

RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
REDSHIFT_ENDPOINT=$(terraform output -raw redshift_endpoint)

# 3. Get passwords manually (without jq)
echo ""
echo "Getting RDS password from Secrets Manager..."
RDS_SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?contains(Name,'oracle-cdc-demo-rds-oracle-master')].Name | [0]" --output text)

if [ ! -z "$RDS_SECRET_NAME" ]; then
    RDS_SECRET=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_NAME" --query SecretString --output text)
    # Extract password using sed/awk instead of jq
    RDS_PASSWORD=$(echo $RDS_SECRET | sed 's/.*"password":"\([^"]*\)".*/\1/')
else
    echo "❌ RDS secret not found!"
fi

echo "Getting Redshift password from Secrets Manager..."
REDSHIFT_SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?contains(Name,'oracle-cdc-demo-redshift-master')].Name | [0]" --output text)

if [ ! -z "$REDSHIFT_SECRET_NAME" ]; then
    REDSHIFT_SECRET=$(aws secretsmanager get-secret-value --secret-id "$REDSHIFT_SECRET_NAME" --query SecretString --output text)
    REDSHIFT_PASSWORD=$(echo $REDSHIFT_SECRET | sed 's/.*"password":"\([^"]*\)".*/\1/')
else
    echo "❌ Redshift secret not found!"
fi

cd ../../..

# 4. Display manual setup instructions
echo ""
echo "⚠️  Manual Database Setup Required:"
echo ""
echo "1. Connect to Oracle:"
echo "   Endpoint: $RDS_ENDPOINT"
echo "   Username: admin"
echo "   Password: $RDS_PASSWORD"
echo "   Run: scripts/init/01-init-oracle-db.sql"
echo ""
echo "2. Connect to Redshift:"
echo "   Endpoint: $REDSHIFT_ENDPOINT"
echo "   Database: cdcdemo"
echo "   Username: admin"
echo "   Password: $REDSHIFT_PASSWORD"
echo "   Run: scripts/init/02-init-redshift.sql"
echo ""
echo "3. Kafka topics will be created by:"
echo "   kubectl apply -f scripts/init/03-create-topics.yaml"