#!/bin/bash
# Complete cleanup with proper dependency order
# Fixed for all dependency issues

set -e

# Configuration
PROJECT_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"
LOG_FILE="deletion-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Functions
log_info() { 
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a $LOG_FILE
}

log_warn() { 
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a $LOG_FILE
}

log_error() { 
    echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE
}

log_action() { 
    echo -e "${BLUE}[ACTION]${NC} $1" | tee -a $LOG_FILE
}

log_section() {
    echo -e "\n${CYAN}========== $1 ==========${NC}" | tee -a $LOG_FILE
}

# Wait function with status check
wait_for_resource_deletion() {
    local resource_type=$1
    local resource_id=$2
    local check_cmd=$3
    local max_wait=${4:-300}  # Default 5 minutes
    
    log_info "Waiting for $resource_type $resource_id to be deleted..."
    
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if ! eval "$check_cmd" >/dev/null 2>&1; then
            log_info "$resource_type $resource_id deleted successfully"
            return 0
        fi
        
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_warn "Timeout waiting for $resource_type $resource_id deletion"
    return 1
}

# Safety check
clear
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     ⚠️  WARNING: COMPLETE RESOURCE DELETION SCRIPT ⚠️         ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║ This will DELETE ALL resources with:                         ║${NC}"
echo -e "${RED}║ Project = ${YELLOW}$PROJECT_TAG${RED}                       ║${NC}"
echo -e "${RED}║ Region  = ${YELLOW}$REGION${RED}                                  ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║           THIS ACTION CANNOT BE UNDONE!                      ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Type 'DELETE-ALL-RESOURCES' to confirm: " confirm

if [ "$confirm" != "DELETE-ALL-RESOURCES" ]; then
    echo "Cancelled."
    exit 0
fi

log_info "Starting deletion process at $(date)"

# ======================== Phase 1: Delete EKS and Compute Resources ========================
log_section "Phase 1: Delete EKS Clusters and Node Groups"

# First, get EKS cluster name
EKS_CLUSTER=$(aws eks list-clusters --region $REGION --query "clusters[?contains(@, 'oracle-cdc-pipeline')]" --output text 2>/dev/null | head -1)

if [ ! -z "$EKS_CLUSTER" ]; then
    log_action "Found EKS cluster: $EKS_CLUSTER"
    
    # Delete all K8s services to remove load balancers
    log_action "Deleting Kubernetes services..."
    kubectl delete svc --all -A 2>/dev/null || true
    
    # Delete node groups first
    NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $EKS_CLUSTER --region $REGION --query 'nodegroups[]' --output text 2>/dev/null || echo "")
    
    for ng in $NODE_GROUPS; do
        log_action "Deleting node group: $ng"
        aws eks delete-nodegroup --cluster-name $EKS_CLUSTER --nodegroup-name $ng --region $REGION || true
    done
    
    # Wait for all node groups to be deleted
    for ng in $NODE_GROUPS; do
        wait_for_resource_deletion "nodegroup" "$ng" \
            "aws eks describe-nodegroup --cluster-name $EKS_CLUSTER --nodegroup-name $ng --region $REGION" \
            600  # 10 minutes
    done
    
    # Now delete the cluster
    log_action "Deleting EKS cluster: $EKS_CLUSTER"
    aws eks delete-cluster --name $EKS_CLUSTER --region $REGION || true
    
    # Wait for cluster deletion
    wait_for_resource_deletion "EKS cluster" "$EKS_CLUSTER" \
        "aws eks describe-cluster --name $EKS_CLUSTER --region $REGION" \
        600
fi

# ======================== Phase 2: Terminate EC2 Instances ========================
log_section "Phase 2: Terminate All EC2 Instances"

# Get all instances with our tag
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ ! -z "$INSTANCES" ]; then
    log_action "Terminating EC2 instances: $INSTANCES"
    aws ec2 terminate-instances --instance-ids $INSTANCES --region $REGION || true
    
    # Wait for termination
    for instance in $INSTANCES; do
        wait_for_resource_deletion "EC2 instance" "$instance" \
            "aws ec2 describe-instances --instance-ids $instance --region $REGION --query 'Reservations[].Instances[?State.Name!=\`terminated\`]' --output text" \
            300
    done
fi

# ======================== Phase 3: Delete Load Balancers ========================
log_section "Phase 3: Delete Load Balancers"

# Delete all load balancers
LOAD_BALANCERS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-') || contains(LoadBalancerName, 'oracle-cdc')].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

for lb in $LOAD_BALANCERS; do
    if [ ! -z "$lb" ]; then
        log_action "Deleting load balancer: $lb"
        aws elbv2 delete-load-balancer --load-balancer-arn $lb --region $REGION || true
    fi
done

# Wait for LBs to be deleted
sleep 30

# ======================== Phase 4: Delete Database Resources ========================
log_section "Phase 4: Delete Database Resources"

# Check Redshift workgroup status first
WORKGROUP_STATUS=$(aws redshift-serverless describe-workgroups \
    --region $REGION \
    --query "workgroups[?workgroupName=='oracle-cdc-pipeline-workgroup'].status" \
    --output text 2>/dev/null || echo "")

if [ "$WORKGROUP_STATUS" == "DELETING" ]; then
    log_info "Redshift workgroup is already being deleted, waiting..."
    wait_for_resource_deletion "Redshift workgroup" "oracle-cdc-pipeline-workgroup" \
        "aws redshift-serverless describe-workgroups --region $REGION --query \"workgroups[?workgroupName=='oracle-cdc-pipeline-workgroup']\" --output text" \
        600
fi

# Delete Redshift namespace if workgroup is gone
REDSHIFT_NAMESPACES=$(aws redshift-serverless list-namespaces \
    --region $REGION \
    --query "namespaces[?contains(namespaceName, 'oracle-cdc-pipeline')].namespaceName" \
    --output text 2>/dev/null || echo "")

for ns in $REDSHIFT_NAMESPACES; do
    if [ ! -z "$ns" ]; then
        log_action "Deleting Redshift namespace: $ns"
        aws redshift-serverless delete-namespace --namespace-name $ns --region $REGION 2>/dev/null || true
    fi
done

# Delete RDS instances
RDS_INSTANCES=$(aws rds describe-db-instances \
    --region $REGION \
    --query "DBInstances[?contains(DBInstanceIdentifier, 'oracle-cdc-pipeline')].DBInstanceIdentifier" \
    --output text 2>/dev/null || echo "")

for db in $RDS_INSTANCES; do
    if [ ! -z "$db" ]; then
        log_action "Deleting RDS instance: $db"
        aws rds delete-db-instance \
            --db-instance-identifier $db \
            --skip-final-snapshot \
            --delete-automated-backups \
            --region $REGION || true
    fi
done

# ======================== Phase 5: Delete S3 Buckets ========================
log_section "Phase 5: Delete S3 Buckets"

S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'oracle-cdc-pipeline')].Name" --output text 2>/dev/null || echo "")

for bucket in $S3_BUCKETS; do
    if [ ! -z "$bucket" ]; then
        log_action "Emptying and deleting S3 bucket: $bucket"
        aws s3 rm s3://$bucket --recursive 2>/dev/null || true
        aws s3api delete-bucket --bucket $bucket --region $REGION 2>/dev/null || true
    fi
done

# ======================== Phase 6: Delete Network Interfaces ========================
log_section "Phase 6: Delete Network Interfaces"

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "")

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    # Delete all network interfaces in VPC
    ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || echo "")
    
    for eni in $ENIS; do
        if [ ! -z "$eni" ]; then
            # Check if it's attached
            ATTACHMENT=$(aws ec2 describe-network-interfaces \
                --network-interface-ids $eni \
                --region $REGION \
                --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
                --output text 2>/dev/null || echo "")
            
            if [ ! -z "$ATTACHMENT" ] && [ "$ATTACHMENT" != "None" ]; then
                log_action "Detaching network interface: $eni"
                aws ec2 detach-network-interface --attachment-id $ATTACHMENT --region $REGION || true
                sleep 5
            fi
            
            log_action "Deleting network interface: $eni"
            aws ec2 delete-network-interface --network-interface-id $eni --region $REGION || true
        fi
    done
fi

# ======================== Phase 7: Delete VPC Resources ========================
log_section "Phase 7: Delete VPC and Network Resources"

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "Cleaning VPC: $VPC_ID"
    
    # Delete NAT Gateways
    NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
        --output text 2>/dev/null || echo "")
    
    for nat in $NAT_GATEWAYS; do
        if [ ! -z "$nat" ]; then
            log_action "Deleting NAT Gateway: $nat"
            aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $REGION || true
        fi
    done
    
    # Wait for NAT Gateways
    if [ ! -z "$NAT_GATEWAYS" ]; then
        sleep 60
    fi
    
    # Release Elastic IPs
    EIPS=$(aws ec2 describe-addresses \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --region $REGION \
        --query 'Addresses[].AllocationId' \
        --output text 2>/dev/null || echo "")
    
    for eip in $EIPS; do
        if [ ! -z "$eip" ]; then
            log_action "Releasing EIP: $eip"
            aws ec2 release-address --allocation-id $eip --region $REGION || true
        fi
    done
    
    # Delete VPC Endpoints
    VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text 2>/dev/null || echo "")
    
    for endpoint in $VPC_ENDPOINTS; do
        if [ ! -z "$endpoint" ]; then
            log_action "Deleting VPC Endpoint: $endpoint"
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $REGION || true
        fi
    done
    
    # Delete Internet Gateway
    IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
        log_action "Detaching and deleting IGW: $IGW"
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $REGION || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION || true
    fi
    
    # Delete Route Tables
    ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'RouteTables[?Main==`false`].RouteTableId' \
        --output text 2>/dev/null || echo "")
    
    for rt in $ROUTE_TABLES; do
        if [ ! -z "$rt" ]; then
            # First disassociate
            ASSOCIATIONS=$(aws ec2 describe-route-tables \
                --route-table-ids $rt \
                --region $REGION \
                --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
                --output text 2>/dev/null || echo "")
            
            for assoc in $ASSOCIATIONS; do
                if [ ! -z "$assoc" ]; then
                    aws ec2 disassociate-route-table --association-id $assoc --region $REGION || true
                fi
            done
            
            log_action "Deleting route table: $rt"
            aws ec2 delete-route-table --route-table-id $rt --region $REGION || true
        fi
    done
    
    # Delete Security Groups
    log_action "Cleaning Security Groups..."
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[?GroupName!=`default`]' \
        --output json 2>/dev/null || echo "[]")
    
    # First, remove all rules from all security groups
    echo "$SECURITY_GROUPS" | jq -r '.[] | .GroupId' | while read sg; do
        if [ ! -z "$sg" ]; then
            log_action "Removing all rules from security group: $sg"
            
            # Remove all ingress rules
            aws ec2 revoke-security-group-ingress \
                --group-id $sg \
                --region $REGION \
                --ip-permissions "$(echo "$SECURITY_GROUPS" | jq -r ".[] | select(.GroupId==\"$sg\") | .IpPermissions")" 2>/dev/null || true
            
            # Remove all egress rules
            aws ec2 revoke-security-group-egress \
                --group-id $sg \
                --region $REGION \
                --ip-permissions "$(echo "$SECURITY_GROUPS" | jq -r ".[] | select(.GroupId==\"$sg\") | .IpPermissionsEgress")" 2>/dev/null || true
        fi
    done
    
    # Now delete security groups
    echo "$SECURITY_GROUPS" | jq -r '.[] | .GroupId' | while read sg; do
        if [ ! -z "$sg" ]; then
            log_action "Deleting security group: $sg"
            aws ec2 delete-security-group --group-id $sg --region $REGION || true
        fi
    done
    
    # Delete Subnets
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null || echo "")
    
    for subnet in $SUBNETS; do
        if [ ! -z "$subnet" ]; then
            log_action "Deleting subnet: $subnet"
            aws ec2 delete-subnet --subnet-id $subnet --region $REGION || true
        fi
    done
    
    # Delete Network ACLs (non-default)
    NACLS=$(aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'NetworkAcls[?IsDefault==`false`].NetworkAclId' \
        --output text 2>/dev/null || echo "")
    
    for nacl in $NACLS; do
        if [ ! -z "$nacl" ]; then
            log_action "Deleting Network ACL: $nacl"
            aws ec2 delete-network-acl --network-acl-id $nacl --region $REGION || true
        fi
    done
    
    # Finally delete VPC
    log_action "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true
fi

# ======================== Phase 8: Delete Other Resources ========================
log_section "Phase 8: Delete Other AWS Resources"

# Delete CloudWatch Log Groups
log_action "Deleting CloudWatch Log Groups..."
aws logs describe-log-groups \
    --region $REGION \
    --query "logGroups[?contains(logGroupName, 'oracle-cdc-pipeline')].logGroupName" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r lg; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        aws logs delete-log-group --log-group-name "$lg" --region $REGION 2>/dev/null || true
    fi
done

# Delete Secrets
log_action "Deleting Secrets..."
SECRETS=$(aws secretsmanager list-secrets \
    --region $REGION \
    --query "SecretList[?contains(Name, 'oracle-cdc')].Name" \
    --output text 2>/dev/null || echo "")

for secret in $SECRETS; do
    if [ ! -z "$secret" ]; then
        log_action "Deleting secret: $secret"
        aws secretsmanager delete-secret \
            --secret-id "$secret" \
            --force-delete-without-recovery \
            --region $REGION || true
    fi
done

# Delete IAM Roles
log_action "Deleting IAM Roles..."
IAM_ROLES=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, 'oracle-cdc-pipeline')].RoleName" \
    --output text 2>/dev/null || echo "")

for role in $IAM_ROLES; do
    if [ ! -z "$role" ]; then
        # Detach all policies
        aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | \
        while read policy; do
            [ ! -z "$policy" ] && aws iam detach-role-policy --role-name $role --policy-arn $policy || true
        done
        
        # Delete inline policies
        aws iam list-role-policies --role-name $role --query 'PolicyNames[]' --output text 2>/dev/null | \
        while read policy; do
            [ ! -z "$policy" ] && aws iam delete-role-policy --role-name $role --policy-name $policy || true
        done
        
        log_action "Deleting IAM role: $role"
        aws iam delete-role --role-name $role || true
    fi
done

# Delete ECR repositories
ECR_REPOS=$(aws ecr describe-repositories \
    --region $REGION \
    --query "repositories[?contains(repositoryName, 'oracle-cdc-pipeline')].repositoryName" \
    --output text 2>/dev/null || echo "")

for repo in $ECR_REPOS; do
    if [ ! -z "$repo" ]; then
        log_action "Deleting ECR repository: $repo"
        aws ecr delete-repository --repository-name $repo --force --region $REGION || true
    fi
done

# Schedule KMS keys for deletion
log_action "Scheduling KMS keys for deletion..."
KMS_KEYS=$(aws kms list-aliases \
    --region $REGION \
    --query "Aliases[?contains(AliasName, 'oracle-cdc')].TargetKeyId" \
    --output text 2>/dev/null || echo "")

for key in $KMS_KEYS; do
    if [ ! -z "$key" ] && [ "$key" != "None" ]; then
        log_action "Scheduling KMS key for deletion: $key"
        aws kms schedule-key-deletion --key-id $key --pending-window-in-days 7 --region $REGION 2>/dev/null || true
    fi
done

# ======================== Final Check ========================
log_section "Final Resource Check"

REMAINING=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=$PROJECT_TAG \
    --region $REGION \
    --query 'length(ResourceTagMappingList)' \
    --output text 2>/dev/null || echo "0")

log_info "Remaining resources: $REMAINING"

if [ "$REMAINING" -gt "0" ]; then
    log_warn "Some resources still remain:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --output table
fi

# ======================== Summary ========================
log_section "Deletion Summary"
log_info "Process completed at $(date)"
log_info "Log file: $LOG_FILE"

if [ "$REMAINING" -le "5" ]; then
    echo -e "\n${GREEN}✅ DELETION COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}Only KMS keys remain (scheduled for deletion in 7 days)${NC}"
else
    echo -e "\n${YELLOW}⚠️  $REMAINING resources still remain${NC}"
    echo -e "${YELLOW}Run the script again after a few minutes${NC}"
fi

log_info "Cleanup complete!"