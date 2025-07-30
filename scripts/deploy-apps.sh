#!/bin/bash
# Deploy CDC applications to Kubernetes

set -e

# Get values from Terraform
cd terraform/demo
export ORACLE_ENDPOINT=$(terraform output -raw oracle_endpoint)
export ORACLE_PASSWORD=$(terraform output -json | jq -r '.oracle_master_password.value // empty' || echo "${ORACLE_PASSWORD}")
export S3_BUCKET=$(terraform output -raw s3_data_bucket)
export DLQ_BUCKET=$(terraform output -raw s3_dlq_bucket)
export REDSHIFT_ENDPOINT=$(terraform output -raw redshift_endpoint)
export REDSHIFT_ROLE_ARN=$(terraform output -raw redshift_role_arn)
export REDSHIFT_PASSWORD=$(terraform output -json | jq -r '.redshift_master_password.value // empty' || echo "${REDSHIFT_PASSWORD}")
export CONSUMER_IAM_ROLE=$(terraform output -raw consumer_irsa_arn)
cd ../..

# Get ECR repo
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_REGION:-ap-southeast-1}
export ECR_REPO="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/oracle-cdc-pipeline"

# Apply manifests with substitution
envsubst < kubernetes/producer-deployment.yaml | kubectl apply -f -
envsubst < kubernetes/consumer-deployment.yaml | kubectl apply -f -

# Wait for deployments
kubectl rollout status deployment/cdc-producer -n cdc-apps --timeout=300s
kubectl rollout status deployment/cdc-consumer -n cdc-apps --timeout=300s

echo "Applications deployed successfully!"

# Show pod status
echo "Producer pods:"
kubectl get pods -n cdc-apps -l app=cdc-producer

echo "Consumer pods:"
kubectl get pods -n cdc-apps -l app=cdc-consumer