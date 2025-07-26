#!/bin/bash
REGION="ap-southeast-1"
PROJECT_TAG="demo_rt_the_one"

echo "í·¹ Enhanced cleanup - removing ALL resources"

# 1. Delete ECR repositories
echo "Deleting ECR repositories..."
for repo in $(aws ecr describe-repositories --region $REGION --query "repositories[?contains(repositoryName, 'debezium') || contains(repositoryName, 'pii')].repositoryName" --output text); do
  echo "  Deleting ECR repo: $repo"
  aws ecr delete-repository --repository-name $repo --force --region $REGION 2>/dev/null || true
done

# 2. Delete S3 buckets (including terraform state)
echo "Deleting S3 buckets..."
for bucket in $(aws s3api list-buckets --query "Buckets[?contains(Name, 'demo-rt-the-one')].Name" --output text); do
  echo "  Emptying and deleting bucket: $bucket"
  aws s3 rm s3://$bucket --recursive 2>/dev/null || true
  aws s3api delete-bucket --bucket $bucket --region $REGION 2>/dev/null || true
done

# 3. Delete DynamoDB table
echo "Deleting DynamoDB table..."
aws dynamodb delete-table --table-name demo-rt-the-one-terraform-locks --region $REGION 2>/dev/null || true

# 4. Delete Resource Group
echo "Deleting Resource Group..."
aws resource-groups delete-group --group-name demo-rt-the-one-resources --region $REGION 2>/dev/null || true

echo "âœ… Enhanced cleanup complete!"
