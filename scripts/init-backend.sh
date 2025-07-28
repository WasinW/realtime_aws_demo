#!/bin/bash
# Create S3 bucket and DynamoDB table for Terraform state

BUCKET_NAME="oracle-cdc-demo-tfstate"
TABLE_NAME="oracle-cdc-demo-tflock"
REGION="ap-southeast-1"

# Create S3 bucket
aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ${REGION} \
  --create-bucket-configuration LocationConstraint=${REGION}

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

# Create DynamoDB table
aws dynamodb create-table \
  --table-name ${TABLE_NAME} \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region ${REGION}

echo "Backend resources created successfully!"