#!/bin/bash
# Complete cleanup script for oracle-cdc-pipeline
# Fixed for Windows Git Bash compatibility

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

# ======================== Step 1: Stop Running Services ========================
log_section "Step 1: Stopping Running Services"

# Terminate EC2 instances first
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=running,stopped,stopping" \
    --region $REGION \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ ! -z "$INSTANCES" ]; then
    for instance in $INSTANCES; do
        log_action "Terminating EC2 instance: $instance"
        aws ec2 terminate-instances --instance-ids $instance --region $REGION || true
    done
    
    log_info "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCES --region $REGION 2>/dev/null || true
fi

# ======================== Step 2: Delete EKS Resources ========================
log_section "Step 2: Deleting EKS Clusters"

EKS_CLUSTERS=$(aws eks list-clusters --region $REGION --query "clusters[?contains(@, 'oracle-cdc-pipeline')]" --output text 2>/dev/null || echo "")

for cluster in $EKS_CLUSTERS; do
    if [ ! -z "$cluster" ]; then
        log_action "Processing EKS cluster: $cluster"
        
        # Delete services and ingresses first
        kubectl delete svc --all -n kafka 2>/dev/null || true
        kubectl delete svc --all -n cdc-apps 2>/dev/null || true
        kubectl delete ingress --all -n kafka 2>/dev/null || true
        kubectl delete ingress --all -n cdc-apps 2>/dev/null || true
        
        # Delete node groups
        NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $cluster --region $REGION --query 'nodegroups[]' --output text 2>/dev/null || echo "")
        
        for ng in $NODE_GROUPS; do
            log_action "Deleting node group: $ng"
            aws eks delete-nodegroup --cluster-name $cluster --nodegroup-name $ng --region $REGION || true
        done
        
        # Wait for node groups
        if [ ! -z "$NODE_GROUPS" ]; then
            log_info "Waiting for node groups to be deleted..."
            sleep 60
        fi
        
        # Delete cluster
        log_action "Deleting EKS cluster: $cluster"
        aws eks delete-cluster --name $cluster --region $REGION || true
    fi
done

# ======================== Step 3: Delete Load Balancers ========================
log_section "Step 3: Deleting Load Balancers"

# Delete ALBs/NLBs
LOAD_BALANCERS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --query "LoadBalancers[?contains(LoadBalancerName, 'oracle-cdc-pipeline') || contains(Tags[?Key=='Project'].Value | [0], 'oracle-cdc-pipeline')].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

for lb in $LOAD_BALANCERS; do
    if [ ! -z "$lb" ]; then
        log_action "Deleting load balancer: $lb"
        aws elbv2 delete-load-balancer --load-balancer-arn $lb --region $REGION || true
    fi
done

# Wait for LBs to be deleted
if [ ! -z "$LOAD_BALANCERS" ]; then
    sleep 30
fi

# ======================== Step 4: Delete Database Resources ========================
log_section "Step 4: Deleting Database Resources"

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

# Delete Redshift Serverless
log_action "Deleting Redshift Serverless workgroups..."
REDSHIFT_WORKGROUPS=$(aws redshift-serverless list-workgroups \
    --region $REGION \
    --query "workgroups[?contains(workgroupName, 'oracle-cdc-pipeline')].workgroupName" \
    --output text 2>/dev/null || echo "")

for wg in $REDSHIFT_WORKGROUPS; do
    if [ ! -z "$wg" ]; then
        log_action "Deleting Redshift workgroup: $wg"
        aws redshift-serverless delete-workgroup --workgroup-name $wg --region $REGION || true
    fi
done

log_action "Deleting Redshift Serverless namespaces..."
REDSHIFT_NAMESPACES=$(aws redshift-serverless list-namespaces \
    --region $REGION \
    --query "namespaces[?contains(namespaceName, 'oracle-cdc-pipeline')].namespaceName" \
    --output text 2>/dev/null || echo "")

for ns in $REDSHIFT_NAMESPACES; do
    if [ ! -z "$ns" ]; then
        log_action "Deleting Redshift namespace: $ns"
        aws redshift-serverless delete-namespace --namespace-name $ns --region $REGION || true
    fi
done

# ======================== Step 5: Delete S3 Buckets ========================
log_section "Step 5: Deleting S3 Buckets"

S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'oracle-cdc-pipeline')].Name" --output text 2>/dev/null || echo "")

for bucket in $S3_BUCKETS; do
    if [ ! -z "$bucket" ]; then
        log_action "Emptying and deleting S3 bucket: $bucket"
        # Delete all objects
        aws s3 rm s3://$bucket --recursive 2>/dev/null || true
        # Delete all versions
        aws s3api list-object-versions --bucket $bucket --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
            jq -r '.[] | "--key \"\(.Key)\" --version-id \(.VersionId)"' | \
            while read -r line; do
                eval aws s3api delete-object --bucket $bucket $line 2>/dev/null || true
            done
        # Delete bucket
        aws s3api delete-bucket --bucket $bucket --region $REGION || true
    fi
done

# ======================== Step 6: Delete Network Resources ========================
log_section "Step 6: Deleting Network Resources"

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "")

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "Found VPC: $VPC_ID"
    
    # Delete NAT Gateways
    NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
        --region $REGION \
        --query 'NatGateways[].NatGatewayId' \
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
    
    # Detach and Delete Internet Gateway
    IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
        log_action "Detaching IGW: $IGW"
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $REGION || true
        log_action "Deleting IGW: $IGW"
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
            log_action "Deleting route table: $rt"
            aws ec2 delete-route-table --route-table-id $rt --region $REGION || true
        fi
    done
    
    # Delete Network Interfaces
    ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || echo "")
    
    for eni in $ENIS; do
        if [ ! -z "$eni" ]; then
            log_action "Deleting network interface: $eni"
            aws ec2 delete-network-interface --network-interface-id $eni --region $REGION || true
        fi
    done
    
    # Delete Security Groups
    log_action "Deleting Security Groups..."
    # First, remove all rules
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text 2>/dev/null || echo "")
    
    # Remove all rules from security groups
    for sg in $SECURITY_GROUPS; do
        if [ ! -z "$sg" ]; then
            log_action "Removing rules from security group: $sg"
            # Get and revoke all ingress rules
            aws ec2 describe-security-groups \
                --group-ids $sg \
                --region $REGION \
                --query 'SecurityGroups[0].IpPermissions' \
                --output json 2>/dev/null > /tmp/sg-rules.json || echo "[]" > /tmp/sg-rules.json
            
            if [ -s /tmp/sg-rules.json ] && [ "$(cat /tmp/sg-rules.json)" != "[]" ] && [ "$(cat /tmp/sg-rules.json)" != "null" ]; then
                aws ec2 revoke-security-group-ingress \
                    --group-id $sg \
                    --ip-permissions file:///tmp/sg-rules.json \
                    --region $REGION 2>/dev/null || true
            fi
            
            # Get and revoke all egress rules
            aws ec2 describe-security-groups \
                --group-ids $sg \
                --region $REGION \
                --query 'SecurityGroups[0].IpPermissionsEgress' \
                --output json 2>/dev/null > /tmp/sg-rules.json || echo "[]" > /tmp/sg-rules.json
            
            if [ -s /tmp/sg-rules.json ] && [ "$(cat /tmp/sg-rules.json)" != "[]" ] && [ "$(cat /tmp/sg-rules.json)" != "null" ]; then
                aws ec2 revoke-security-group-egress \
                    --group-id $sg \
                    --ip-permissions file:///tmp/sg-rules.json \
                    --region $REGION 2>/dev/null || true
            fi
        fi
    done
    
    # Now delete security groups
    for sg in $SECURITY_GROUPS; do
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
    
    # Finally delete VPC
    log_action "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true
fi

# ======================== Step 7: Delete Other AWS Resources ========================
log_section "Step 7: Deleting Other AWS Resources"

# Delete CloudWatch Log Groups
log_action "Deleting CloudWatch Log Groups..."
# Fix for Windows path issue - get log groups and process them properly
aws logs describe-log-groups \
    --region $REGION \
    --query "logGroups[?contains(logGroupName, 'oracle-cdc-pipeline')].logGroupName" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r lg; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        aws logs delete-log-group --log-group-name "$lg" --region $REGION 2>/dev/null || true
    fi
done

# Delete Secrets Manager secrets
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
        # Detach policies
        POLICIES=$(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
        for policy in $POLICIES; do
            aws iam detach-role-policy --role-name $role --policy-arn $policy || true
        done
        
        # Delete inline policies
        INLINE_POLICIES=$(aws iam list-role-policies --role-name $role --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
        for policy in $INLINE_POLICIES; do
            aws iam delete-role-policy --role-name $role --policy-name $policy || true
        done
        
        # Delete role
        log_action "Deleting IAM role: $role"
        aws iam delete-role --role-name $role || true
    fi
done

# Delete ECR repositories
log_action "Deleting ECR repositories..."
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

# Delete KMS keys (schedule for deletion)
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

# ======================== Step 8: Final Cleanup ========================
log_section "Step 8: Final Cleanup"

# Delete any remaining resources by tag
log_info "Checking for remaining tagged resources..."
REMAINING=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=$PROJECT_TAG \
    --region $REGION \
    --query 'length(ResourceTagMappingList)' \
    --output text 2>/dev/null || echo "0")

if [ "$REMAINING" -gt "0" ]; then
    log_warn "Found $REMAINING remaining resources:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --output table
fi

# Clean up temp files
rm -f /tmp/sg-rules.json

# ======================== Summary ========================
log_section "Deletion Summary"
log_info "Process completed at $(date)"
log_info "Log file: $LOG_FILE"

if [ "$REMAINING" -eq "0" ]; then
    echo -e "\n${GREEN}✅ ALL RESOURCES DELETED SUCCESSFULLY!${NC}"
else
    echo -e "\n${YELLOW}⚠️  $REMAINING resources may still remain. Check the output above.${NC}"
    echo -e "${YELLOW}Some resources like KMS keys are scheduled for deletion in 7 days.${NC}"
fi

# Clean up local files
if [ -f "terraform/demo/terraform.tfstate" ]; then
    log_info "Cleaning up Terraform state files..."
    rm -rf terraform/demo/.terraform terraform/demo/terraform.tfstate* terraform/demo/.terraform.lock.hcl
fi

log_info "Cleanup complete!"