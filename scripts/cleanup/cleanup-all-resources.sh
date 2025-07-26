#!/bin/bash
# cleanup-all-resources.sh - ลบทุก resources ใน resource group

set -e

RESOURCE_GROUP_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"

echo "🧹 Starting cleanup of all resources with tag Project=$RESOURCE_GROUP_TAG"

# Function to delete resources by type
delete_resources() {
    local resource_type=$1
    local delete_command=$2
    
    echo "Deleting $resource_type..."
    
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$RESOURCE_GROUP_TAG \
        --resource-type-filters $resource_type \
        --region $REGION \
        --query 'ResourceTagMappingList[].ResourceARN' \
        --output text | tr '\t' '\n' | while read -r arn; do
        
        if [ ! -z "$arn" ]; then
            echo "  Deleting: $arn"
            eval "$delete_command"
        fi
    done
}

# Delete in order of dependencies
echo "1. Deleting EKS Node Groups..."
aws eks list-nodegroups --cluster-name oracle-cdc-pipeline-demo-eks --region $REGION --query 'nodegroups[]' --output text | \
while read -r nodegroup; do
    echo "  Scaling down nodegroup: $nodegroup"
    aws eks update-nodegroup-config \
        --cluster-name oracle-cdc-pipeline-demo-eks \
        --nodegroup-name $nodegroup \
        --scaling-config minSize=0,maxSize=0,desiredSize=0 \
        --region $REGION || true
done

echo "2. Stopping RDS instances..."
delete_resources "rds:db" "aws rds stop-db-instance --db-instance-identifier \${arn##*/} --region $REGION || true"

echo "3. Pausing Redshift clusters..."
delete_resources "redshift:cluster" "aws redshift pause-cluster --cluster-identifier \${arn##*/} --region $REGION || true"

echo "4. Deleting S3 bucket contents..."
aws s3api list-buckets --query 'Buckets[?contains(Name, `oracle-cdc-pipeline`)].Name' --output text | tr '\t' '\n' | \
while read -r bucket; do
    echo "  Emptying bucket: $bucket"
    aws s3 rm s3://$bucket --recursive || true
done

echo "5. Running Terraform destroy..."
cd terraform/environments/demo
terraform destroy -auto-approve

echo "✅ Cleanup complete!"