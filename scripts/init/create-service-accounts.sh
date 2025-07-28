#!/bin/bash
# create-service-accounts-fixed.sh

# Get Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Creating Kubernetes Service Accounts..."

# 1. Create Service Accounts
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: debezium-connect
  namespace: kafka
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/oracle-cdc-demo-msk-access-role
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pii-masking
  namespace: kafka
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/oracle-cdc-demo-msk-access-role
EOF

# 2. Check if Kafka Connect exists
if kubectl get kafkaconnect debezium-connect-cluster -n kafka &>/dev/null; then
    echo "Kafka Connect found, waiting for deployment..."
    
    # Wait for deployment to be created by Strimzi
    DEPLOYMENT_NAME="debezium-connect-cluster-connect"
    
    # Wait up to 5 minutes for deployment
    for i in {1..60}; do
        if kubectl get deployment $DEPLOYMENT_NAME -n kafka &>/dev/null; then
            echo "Deployment found, patching with service account..."
            kubectl patch deployment $DEPLOYMENT_NAME -n kafka \
                -p '{"spec":{"template":{"spec":{"serviceAccountName":"debezium-connect"}}}}'
            break
        fi
        echo "Waiting for deployment to be created... ($i/60)"
        sleep 5
    done
else
    echo "❌ Kafka Connect not found. Please create it first:"
    echo "kubectl apply -f kubernetes/debezium/03-kafka-connect.yaml"
fi