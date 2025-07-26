#!/bin/bash
REGION="ap-southeast-1"
PROJECT_TAG="demo_rt_the_one"

echo "í´´ Stopping all services..."

# Stop EKS nodes
aws eks update-nodegroup-config \
  --cluster-name oracle-cdc-pipeline-demo-eks \
  --nodegroup-name debezium \
  --scaling-config minSize=0,maxSize=0,desiredSize=0 \
  --region $REGION 2>/dev/null || true

# Stop RDS
aws rds stop-db-instance \
  --db-instance-identifier oracle-cdc-pipeline-demo-oracle \
  --region $REGION 2>/dev/null || true

# Pause Redshift
aws redshift pause-cluster \
  --cluster-identifier oracle-cdc-pipeline-demo-redshift \
  --region $REGION 2>/dev/null || true

# Empty S3 buckets
for bucket in $(aws s3api list-buckets --query "Buckets[?contains(Name, 'oracle-cdc-pipeline')].Name" --output text); do
  echo "Emptying bucket: $bucket"
  aws s3 rm s3://$bucket --recursive 2>/dev/null || true
done

# Terraform destroy
cd terraform/environments/demo
terraform destroy -auto-approve

echo "âœ… All services cleared!"
