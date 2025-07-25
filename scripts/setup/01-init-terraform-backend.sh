#!/bin/bash
# scripts/setup/01-init-terraform-backend.sh

set -e

echo "Creating Terraform backend resources..."

# REGION="ap-southeast-1"
REGION="ap-southeast-1"  # เปลี่ยนจาก ap-southeast-1
BUCKET_NAME="demo-rt-the-one-terraform-state"
DYNAMODB_TABLE="demo-rt-the-one-terraform-locks"

# Create S3 bucket for Terraform state
aws s3api create-bucket \
    --bucket ${BUCKET_NAME} \
    --region ${REGION} \
    --create-bucket-configuration LocationConstraint=${REGION} 2>/dev/null || echo "Bucket already exists"

# Enable versioning
aws s3api put-bucket-versioning \
    --bucket ${BUCKET_NAME} \
    --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
    --bucket ${BUCKET_NAME} \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
    --table-name ${DYNAMODB_TABLE} \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region ${REGION} 2>/dev/null || echo "Table already exists"

# Tag resources
aws s3api put-bucket-tagging \
    --bucket ${BUCKET_NAME} \
    --tagging '{
        "TagSet": [
            {"Key": "Project", "Value": "demo_rt_the_one"},
            {"Key": "Environment", "Value": "demo"},
            {"Key": "ManagedBy", "Value": "terraform"}
        ]
    }'

aws dynamodb tag-resource \
    --resource-arn arn:aws:dynamodb:${REGION}:$(aws sts get-caller-identity --query Account --output text):table/${DYNAMODB_TABLE} \
    --tags Key=Project,Value=demo_rt_the_one Key=Environment,Value=demo Key=ManagedBy,Value=terraform

echo "Terraform backend setup complete!"
