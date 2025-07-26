#!/bin/bash
# delete-all-resources.sh - Complete cleanup of oracle-cdc-pipeline resources

set -e

# Configuration
RESOURCE_GROUP_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"
DRY_RUN=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--force]"
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_action() {
    echo -e "${BLUE}[ACTION]${NC} $1"
}

# Safety check
if [ "$FORCE" != "true" ] && [ "$DRY_RUN" != "true" ]; then
    echo -e "${RED}⚠️  WARNING: This will delete ALL resources tagged with Project=$RESOURCE_GROUP_TAG${NC}"
    echo -e "${RED}This action cannot be undone!${NC}"
    read -p "Are you sure you want to continue? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

if [ "$DRY_RUN" = "true" ]; then
    log_info "Running in DRY RUN mode - no resources will be deleted"
fi

# Function to execute or dry run
execute_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[DRY RUN]${NC} $@"
    else
        eval "$@"
    fi
}

# Function to get resources by type
get_resources_by_type() {
    local resource_type=$1
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$RESOURCE_GROUP_TAG \
        --resource-type-filters $resource_type \
        --region $REGION \
        --query 'ResourceTagMappingList[].ResourceARN' \
        --output text 2>/dev/null | tr '\t' '\n'
}

# 1. Stop/Scale down running services first
log_info "Step 1: Stopping running services..."

# Scale down EKS node groups
log_action "Scaling down EKS node groups..."
eks_clusters=$(get_resources_by_type "eks:cluster")
for cluster_arn in $eks_clusters; do
    if [ ! -z "$cluster_arn" ]; then
        cluster_name=$(echo $cluster_arn | awk -F'/' '{print $NF}')
        log_action "Processing EKS cluster: $cluster_name"
        
        # Get node groups
        nodegroups=$(aws eks list-nodegroups --cluster-name $cluster_name --region $REGION --query 'nodegroups[]' --output text 2>/dev/null || true)
        for nodegroup in $nodegroups; do
            log_action "Scaling down nodegroup: $nodegroup"
            execute_cmd "aws eks update-nodegroup-config \
                --cluster-name $cluster_name \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=0,maxSize=0,desiredSize=0 \
                --region $REGION || true"
        done
    fi
done

# Stop RDS instances
log_action "Stopping RDS instances..."
rds_instances=$(get_resources_by_type "rds:db")
for db_arn in $rds_instances; do
    if [ ! -z "$db_arn" ]; then
        db_id=$(echo $db_arn | awk -F':' '{print $NF}')
        log_action "Stopping RDS instance: $db_id"
        execute_cmd "aws rds stop-db-instance --db-instance-identifier $db_id --region $REGION || true"
    fi
done

# Pause Redshift clusters
log_action "Pausing Redshift clusters..."
redshift_clusters=$(get_resources_by_type "redshift:cluster")
for cluster_arn in $redshift_clusters; do
    if [ ! -z "$cluster_arn" ]; then
        cluster_id=$(echo $cluster_arn | awk -F':' '{print $NF}')
        log_action "Pausing Redshift cluster: $cluster_id"
        execute_cmd "aws redshift pause-cluster --cluster-identifier $cluster_id --region $REGION || true"
    fi
done

# 2. Delete resources in dependency order
log_info "Step 2: Deleting resources in dependency order..."

# Delete ALBs and Target Groups first
log_action "Deleting Load Balancers..."
for lb_arn in $(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?contains(LoadBalancerArn, '$RESOURCE_GROUP_TAG')].LoadBalancerArn" --output text 2>/dev/null); do
    if [ ! -z "$lb_arn" ]; then
        log_action "Deleting load balancer: $lb_arn"
        execute_cmd "aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn --region $REGION || true"
    fi
done

# Delete Target Groups
log_action "Deleting Target Groups..."
for tg_arn in $(aws elbv2 describe-target-groups --region $REGION --query "TargetGroups[?contains(TargetGroupArn, '$RESOURCE_GROUP_TAG')].TargetGroupArn" --output text 2>/dev/null); do
    if [ ! -z "$tg_arn" ]; then
        log_action "Deleting target group: $tg_arn"
        execute_cmd "aws elbv2 delete-target-group --target-group-arn $tg_arn --region $REGION || true"
    fi
done

# Wait a bit for LB deletion
if [ "$DRY_RUN" != "true" ]; then
    sleep 10
fi

# Delete EKS clusters (this will also delete node groups)
log_action "Deleting EKS clusters..."
for cluster_arn in $eks_clusters; do
    if [ ! -z "$cluster_arn" ]; then
        cluster_name=$(echo $cluster_arn | awk -F'/' '{print $NF}')
        
        # Delete node groups first
        nodegroups=$(aws eks list-nodegroups --cluster-name $cluster_name --region $REGION --query 'nodegroups[]' --output text 2>/dev/null || true)
        for nodegroup in $nodegroups; do
            log_action "Deleting nodegroup: $nodegroup"
            execute_cmd "aws eks delete-nodegroup --cluster-name $cluster_name --nodegroup-name $nodegroup --region $REGION || true"
        done
        
        # Wait for node groups to be deleted
        if [ "$DRY_RUN" != "true" ] && [ ! -z "$nodegroups" ]; then
            log_info "Waiting for node groups to be deleted..."
            aws eks wait nodegroup-deleted --cluster-name $cluster_name --nodegroup-name $nodegroup --region $REGION 2>/dev/null || true
        fi
        
        # Delete cluster
        log_action "Deleting EKS cluster: $cluster_name"
        execute_cmd "aws eks delete-cluster --name $cluster_name --region $REGION || true"
    fi
done

# Delete MSK clusters
log_action "Deleting MSK clusters..."
msk_clusters=$(get_resources_by_type "kafka:cluster")
for cluster_arn in $msk_clusters; do
    if [ ! -z "$cluster_arn" ]; then
        log_action "Deleting MSK cluster: $cluster_arn"
        execute_cmd "aws kafka delete-cluster --cluster-arn $cluster_arn --region $REGION || true"
    fi
done

# Delete RDS instances
log_action "Deleting RDS instances..."
for db_arn in $rds_instances; do
    if [ ! -z "$db_arn" ]; then
        db_id=$(echo $db_arn | awk -F':' '{print $NF}')
        log_action "Deleting RDS instance: $db_id"
        execute_cmd "aws rds delete-db-instance \
            --db-instance-identifier $db_id \
            --skip-final-snapshot \
            --delete-automated-backups \
            --region $REGION || true"
    fi
done

# Delete Redshift clusters
log_action "Deleting Redshift clusters..."
for cluster_arn in $redshift_clusters; do
    if [ ! -z "$cluster_arn" ]; then
        cluster_id=$(echo $cluster_arn | awk -F':' '{print $NF}')
        log_action "Deleting Redshift cluster: $cluster_id"
        execute_cmd "aws redshift delete-cluster \
            --cluster-identifier $cluster_id \
            --skip-final-cluster-snapshot \
            --region $REGION || true"
    fi
done

# Delete DB subnet groups
log_action "Deleting DB subnet groups..."
for sg in $(aws rds describe-db-subnet-groups --region $REGION --query "DBSubnetGroups[?contains(DBSubnetGroupName, '$RESOURCE_GROUP_TAG')].DBSubnetGroupName" --output text 2>/dev/null); do
    if [ ! -z "$sg" ]; then
        log_action "Deleting DB subnet group: $sg"
        execute_cmd "aws rds delete-db-subnet-group --db-subnet-group-name $sg --region $REGION || true"
    fi
done

# Delete Redshift subnet groups
log_action "Deleting Redshift subnet groups..."
for sg in $(aws redshift describe-cluster-subnet-groups --region $REGION --query "ClusterSubnetGroups[?contains(ClusterSubnetGroupName, '$RESOURCE_GROUP_TAG')].ClusterSubnetGroupName" --output text 2>/dev/null); do
    if [ ! -z "$sg" ]; then
        log_action "Deleting Redshift subnet group: $sg"
        execute_cmd "aws redshift delete-cluster-subnet-group --cluster-subnet-group-name $sg --region $REGION || true"
    fi
done

# Empty and delete S3 buckets
log_action "Deleting S3 buckets..."
s3_buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, '$RESOURCE_GROUP_TAG')].Name" --output text 2>/dev/null)
for bucket in $s3_buckets; do
    if [ ! -z "$bucket" ]; then
        log_action "Emptying and deleting S3 bucket: $bucket"
        if [ "$DRY_RUN" != "true" ]; then
            aws s3 rm s3://$bucket --recursive 2>/dev/null || true
            aws s3api delete-bucket --bucket $bucket --region $REGION 2>/dev/null || true
        else
            echo -e "${BLUE}[DRY RUN]${NC} aws s3 rm s3://$bucket --recursive"
            echo -e "${BLUE}[DRY RUN]${NC} aws s3api delete-bucket --bucket $bucket --region $REGION"
        fi
    fi
done

# Delete VPC endpoints
log_action "Deleting VPC endpoints..."
vpc_endpoints=$(aws ec2 describe-vpc-endpoints --region $REGION --query "VpcEndpoints[?contains(Tags[?Key=='Project'].Value | [0], '$RESOURCE_GROUP_TAG')].VpcEndpointId" --output text 2>/dev/null)
for endpoint in $vpc_endpoints; do
    if [ ! -z "$endpoint" ]; then
        log_action "Deleting VPC endpoint: $endpoint"
        execute_cmd "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $REGION || true"
    fi
done

# Delete NAT Gateways
log_action "Deleting NAT Gateways..."
nat_gateways=$(aws ec2 describe-nat-gateways --region $REGION --query "NatGateways[?State!='deleted' && contains(Tags[?Key=='Project'].Value | [0], '$RESOURCE_GROUP_TAG')].NatGatewayId" --output text 2>/dev/null)
for nat in $nat_gateways; do
    if [ ! -z "$nat" ]; then
        log_action "Deleting NAT Gateway: $nat"
        execute_cmd "aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $REGION || true"
    fi
done

# Wait for NAT gateways to be deleted
if [ "$DRY_RUN" != "true" ] && [ ! -z "$nat_gateways" ]; then
    log_info "Waiting for NAT gateways to be deleted..."
    sleep 30
fi

# Release Elastic IPs
log_action "Releasing Elastic IPs..."
eips=$(aws ec2 describe-addresses --region $REGION --query "Addresses[?contains(Tags[?Key=='Project'].Value | [0], '$RESOURCE_GROUP_TAG')].AllocationId" --output text 2>/dev/null)
for eip in $eips; do
    if [ ! -z "$eip" ]; then
        log_action "Releasing EIP: $eip"
        execute_cmd "aws ec2 release-address --allocation-id $eip --region $REGION || true"
    fi
done

# Delete Internet Gateways (detach first)
log_action "Deleting Internet Gateways..."
vpcs=$(aws ec2 describe-vpcs --region $REGION --query "Vpcs[?contains(Tags[?Key=='Project'].Value | [0], '$RESOURCE_GROUP_TAG')].VpcId" --output text 2>/dev/null)
for vpc in $vpcs; do
    if [ ! -z "$vpc" ]; then
        igws=$(aws ec2 describe-internet-gateways --region $REGION --query "InternetGateways[?Attachments[?VpcId=='$vpc']].InternetGatewayId" --output text 2>/dev/null)
        for igw in $igws; do
            if [ ! -z "$igw" ]; then
                log_action "Detaching and deleting IGW: $igw"
                execute_cmd "aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc --region $REGION || true"
                execute_cmd "aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $REGION || true"
            fi
        done
    fi
done

# Delete route tables (non-main)
log_action "Deleting route tables..."
for vpc in $vpcs; do
    if [ ! -z "$vpc" ]; then
        route_tables=$(aws ec2 describe-route-tables --region $REGION --query "RouteTables[?VpcId=='$vpc' && !Main].RouteTableId" --output text 2>/dev/null)
        for rt in $route_tables; do
            if [ ! -z "$rt" ]; then
                log_action "Deleting route table: $rt"
                execute_cmd "aws ec2 delete-route-table --route-table-id $rt --region $REGION || true"
            fi
        done
    fi
done

# Delete security groups (non-default)
log_action "Deleting security groups..."
for vpc in $vpcs; do
    if [ ! -z "$vpc" ]; then
        sgs=$(aws ec2 describe-security-groups --region $REGION --query "SecurityGroups[?VpcId=='$vpc' && GroupName!='default'].GroupId" --output text 2>/dev/null)
        for sg in $sgs; do
            if [ ! -z "$sg" ]; then
                log_action "Deleting security group: $sg"
                execute_cmd "aws ec2 delete-security-group --group-id $sg --region $REGION || true"
            fi
        done
    fi
done

# Delete subnets
log_action "Deleting subnets..."
subnets=$(aws ec2 describe-subnets --region $REGION --query "Subnets[?contains(Tags[?Key=='Project'].Value | [0], '$RESOURCE_GROUP_TAG')].SubnetId" --output text 2>/dev/null)
for subnet in $subnets; do
    if [ ! -z "$subnet" ]; then
        log_action "Deleting subnet: $subnet"
        execute_cmd "aws ec2 delete-subnet --subnet-id $subnet --region $REGION || true"
    fi
done

# Delete VPCs
log_action "Deleting VPCs..."
for vpc in $vpcs; do
    if [ ! -z "$vpc" ]; then
        log_action "Deleting VPC: $vpc"
        execute_cmd "aws ec2 delete-vpc --vpc-id $vpc --region $REGION || true"
    fi
done

# Delete CloudWatch log groups
log_action "Deleting CloudWatch log groups..."
log_groups=$(aws logs describe-log-groups --region $REGION --query "logGroups[?contains(logGroupName, '$RESOURCE_GROUP_TAG')].logGroupName" --output text 2>/dev/null)
for lg in $log_groups; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        execute_cmd "aws logs delete-log-group --log-group-name $lg --region $REGION || true"
    fi
done

# Delete Secrets Manager secrets
log_action "Deleting Secrets Manager secrets..."
secrets=$(aws secretsmanager list-secrets --region $REGION --query "SecretList[?contains(Name, '$RESOURCE_GROUP_TAG')].Name" --output text 2>/dev/null)
for secret in $secrets; do
    if [ ! -z "$secret" ]; then
        log_action "Deleting secret: $secret"
        execute_cmd "aws secretsmanager delete-secret --secret-id $secret --force-delete-without-recovery --region $REGION || true"
    fi
done

# Delete IAM roles (be careful here)
log_action "Deleting IAM roles..."
iam_roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '$RESOURCE_GROUP_TAG')].RoleName" --output text 2>/dev/null)
for role in $iam_roles; do
    if [ ! -z "$role" ]; then
        # Detach policies first
        policies=$(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
        for policy in $policies; do
            log_action "Detaching policy $policy from role $role"
            execute_cmd "aws iam detach-role-policy --role-name $role --policy-arn $policy || true"
        done
        
        # Delete inline policies
        inline_policies=$(aws iam list-role-policies --role-name $role --query 'PolicyNames[]' --output text 2>/dev/null)
        for policy in $inline_policies; do
            log_action "Deleting inline policy $policy from role $role"
            execute_cmd "aws iam delete-role-policy --role-name $role --policy-name $policy || true"
        done
        
        # Delete role
        log_action "Deleting IAM role: $role"
        execute_cmd "aws iam delete-role --role-name $role || true"
    fi
done

# Delete Parameter Store parameters
log_action "Deleting Parameter Store parameters..."
params=$(aws ssm describe-parameters --region $REGION --query "Parameters[?contains(Name, '$RESOURCE_GROUP_TAG')].Name" --output text 2>/dev/null)
for param in $params; do
    if [ ! -z "$param" ]; then
        log_action "Deleting parameter: $param"
        execute_cmd "aws ssm delete-parameter --name $param --region $REGION || true"
    fi
done

# Final check - list any remaining resources
log_info "Step 3: Checking for remaining resources..."
remaining=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=$RESOURCE_GROUP_TAG \
    --region $REGION \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text 2>/dev/null | wc -l)

if [ "$remaining" -gt 0 ]; then
    log_warn "Found $remaining remaining resources:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$RESOURCE_GROUP_TAG \
        --region $REGION \
        --query 'ResourceTagMappingList[].[ResourceARN,Tags[?Key==`Name`].Value|[0]]' \
        --output table
else
    log_info "All resources have been deleted successfully!"
fi

# Clean up Terraform state if exists
if [ -d "terraform/environments/demo" ] && [ "$DRY_RUN" != "true" ]; then
    log_info "Cleaning up Terraform state..."
    cd terraform/environments/demo
    if [ -f ".terraform/terraform.tfstate" ]; then
        rm -rf .terraform terraform.tfstate* .terraform.lock.hcl
        log_info "Terraform state cleaned"
    fi
    cd - > /dev/null
fi

log_info "Cleanup complete!"