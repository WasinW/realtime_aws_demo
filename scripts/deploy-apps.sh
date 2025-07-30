#!/bin/bash
# Deploy CDC applications to Kubernetes

set -e

# Get values from Terraform
cd terraform/demo
export ORACLE_ENDPOINT=$(terraform output -raw oracle_endpoint)
export S3_BUCKET=$(terraform output -raw s3_data_bucket)
export DLQ_BUCKET=$(terraform output -raw s3_dlq_bucket)
export REDSHIFT_ENDPOINT=$(terraform output -raw redshift_endpoint)
export REDSHIFT_ROLE_ARN=$(terraform output -raw redshift_role_arn)
cd ../..

# Get ECR repo
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_REGION:-ap-southeast-1}
export ECR_REPO="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/oracle-cdc-demo"

# Create IRSA for consumer
eksctl create iamserviceaccount \
  --name cdc-consumer \
  --namespace cdc-apps \
  --cluster oracle-cdc-demo-eks \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
  --approve \
  --override-existing-serviceaccounts

# Apply manifests with substitution
envsubst < kubernetes/producer-deployment.yaml | kubectl apply -f -
envsubst < kubernetes/consumer-deployment.yaml | kubectl apply -f -

# Wait for deployments
kubectl rollout status deployment/cdc-producer -n cdc-apps
kubectl rollout status deployment/cdc-consumer -n cdc-apps

echo "Applications deployed successfully!"