#!/bin/bash
# delete-remaining-resources.sh - ลบ VPC, Security Groups, Secrets ที่เหลือ

set -e

# Configuration
PROJECT_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_action() { echo -e "${BLUE}[ACTION]${NC} $1"; }

# Safety check
echo -e "${RED}⚠️  WARNING: This will delete remaining VPC resources${NC}"
read -p "Are you sure? Type 'DELETE' to confirm: " confirm
if [ "$confirm" != "DELETE" ]; then
    echo "Cancelled."
    exit 0
fi

# Function to get VPC ID from project tag
get_vpc_id() {
    aws ec2 describe-vpcs \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --region $REGION \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo ""
}

# Function to wait for resource deletion
wait_for_deletion() {
    local resource_type=$1
    local check_command=$2
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if ! eval "$check_command" >/dev/null 2>&1; then
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    return 1
}

# 1. Delete Secrets Manager secrets
log_info "Step 1: Deleting Secrets Manager secrets..."
SECRETS=$(aws secretsmanager list-secrets \
    --region $REGION \
    --query "SecretList[?contains(Name, '$PROJECT_TAG')].Name" \
    --output text 2>/dev/null)

for secret in $SECRETS; do
    if [ ! -z "$secret" ]; then
        log_action "Deleting secret: $secret"
        aws secretsmanager delete-secret \
            --secret-id "$secret" \
            --force-delete-without-recovery \
            --region $REGION || true
    fi
done

# 2. Get VPC ID
VPC_ID=$(get_vpc_id)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    log_error "No VPC found with Project tag: $PROJECT_TAG"
    exit 1
fi

log_info "Found VPC: $VPC_ID"

# 3. Delete VPC Endpoints
log_info "Step 2: Deleting VPC Endpoints..."
VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'VpcEndpoints[].VpcEndpointId' \
    --output text 2>/dev/null)

for endpoint in $VPC_ENDPOINTS; do
    if [ ! -z "$endpoint" ]; then
        log_action "Deleting VPC endpoint: $endpoint"
        aws ec2 delete-vpc-endpoints \
            --vpc-endpoint-ids $endpoint \
            --region $REGION || true
    fi
done

# Wait for endpoints to be deleted
if [ ! -z "$VPC_ENDPOINTS" ]; then
    log_info "Waiting for VPC endpoints to be deleted..."
    sleep 10
fi

# 4. Delete NAT Gateways if any remain
log_info "Step 3: Checking for NAT Gateways..."
NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
    --region $REGION \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null)

for nat in $NAT_GATEWAYS; do
    if [ ! -z "$nat" ]; then
        log_action "Deleting NAT Gateway: $nat"
        aws ec2 delete-nat-gateway \
            --nat-gateway-id $nat \
            --region $REGION || true
    fi
done

# Wait for NAT gateways
if [ ! -z "$NAT_GATEWAYS" ]; then
    log_info "Waiting for NAT gateways to be deleted (this may take a while)..."
    for nat in $NAT_GATEWAYS; do
        wait_for_deletion "NAT Gateway" "aws ec2 describe-nat-gateways --nat-gateway-ids $nat --region $REGION 2>/dev/null | grep -q available"
    done
fi

# 5. Release Elastic IPs
log_info "Step 4: Releasing Elastic IPs..."
EIPS=$(aws ec2 describe-addresses \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Addresses[].AllocationId' \
    --output text 2>/dev/null)

for eip in $EIPS; do
    if [ ! -z "$eip" ]; then
        log_action "Releasing EIP: $eip"
        aws ec2 release-address \
            --allocation-id $eip \
            --region $REGION || true
    fi
done

# 6. Delete Internet Gateway
log_info "Step 5: Detaching and deleting Internet Gateway..."
IGW=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text 2>/dev/null)

if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
    log_action "Detaching IGW: $IGW from VPC: $VPC_ID"
    aws ec2 detach-internet-gateway \
        --internet-gateway-id $IGW \
        --vpc-id $VPC_ID \
        --region $REGION || true
    
    log_action "Deleting IGW: $IGW"
    aws ec2 delete-internet-gateway \
        --internet-gateway-id $IGW \
        --region $REGION || true
fi

# 7. Delete Route Tables (non-main)
log_info "Step 6: Deleting Route Tables..."
ROUTE_TABLES=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'RouteTables[?Main==`false`].RouteTableId' \
    --output text 2>/dev/null)

for rt in $ROUTE_TABLES; do
    if [ ! -z "$rt" ]; then
        # First, disassociate all subnets
        ASSOCIATIONS=$(aws ec2 describe-route-tables \
            --route-table-ids $rt \
            --region $REGION \
            --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
            --output text 2>/dev/null)
        
        for assoc in $ASSOCIATIONS; do
            if [ ! -z "$assoc" ]; then
                log_action "Disassociating route table association: $assoc"
                aws ec2 disassociate-route-table \
                    --association-id $assoc \
                    --region $REGION || true
            fi
        done
        
        log_action "Deleting route table: $rt"
        aws ec2 delete-route-table \
            --route-table-id $rt \
            --region $REGION || true
    fi
done

# 8. Delete Security Groups
log_info "Step 7: Deleting Security Groups..."

# First, remove all ingress and egress rules from non-default security groups
SECURITY_GROUPS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null)

log_info "Removing security group rules..."
for sg in $SECURITY_GROUPS; do
    if [ ! -z "$sg" ]; then
        # Get and remove all ingress rules
        aws ec2 describe-security-groups \
            --group-ids $sg \
            --region $REGION \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null > /tmp/sg-ingress-$sg.json
        
        if [ -s /tmp/sg-ingress-$sg.json ] && [ "$(cat /tmp/sg-ingress-$sg.json)" != "[]" ]; then
            aws ec2 revoke-security-group-ingress \
                --group-id $sg \
                --ip-permissions file:///tmp/sg-ingress-$sg.json \
                --region $REGION || true
        fi
        
        # Get and remove all egress rules
        aws ec2 describe-security-groups \
            --group-ids $sg \
            --region $REGION \
            --query 'SecurityGroups[0].IpPermissionsEgress' \
            --output json 2>/dev/null > /tmp/sg-egress-$sg.json
        
        if [ -s /tmp/sg-egress-$sg.json ] && [ "$(cat /tmp/sg-egress-$sg.json)" != "[]" ]; then
            aws ec2 revoke-security-group-egress \
                --group-id $sg \
                --ip-permissions file:///tmp/sg-egress-$sg.json \
                --region $REGION || true
        fi
        
        rm -f /tmp/sg-ingress-$sg.json /tmp/sg-egress-$sg.json
    fi
done

# Now delete security groups
log_info "Deleting security groups..."
for sg in $SECURITY_GROUPS; do
    if [ ! -z "$sg" ]; then
        SG_NAME=$(aws ec2 describe-security-groups \
            --group-ids $sg \
            --region $REGION \
            --query 'SecurityGroups[0].GroupName' \
            --output text 2>/dev/null)
        
        log_action "Deleting security group: $sg ($SG_NAME)"
        aws ec2 delete-security-group \
            --group-id $sg \
            --region $REGION || true
    fi
done

# 9. Delete Subnets
log_info "Step 8: Deleting Subnets..."
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null)

for subnet in $SUBNETS; do
    if [ ! -z "$subnet" ]; then
        log_action "Deleting subnet: $subnet"
        aws ec2 delete-subnet \
            --subnet-id $subnet \
            --region $REGION || true
    fi
done

# 10. Finally, delete the VPC
log_info "Step 9: Deleting VPC..."
log_action "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc \
    --vpc-id $VPC_ID \
    --region $REGION || true

# 11. Delete any remaining CloudWatch Log Groups
log_info "Step 10: Deleting CloudWatch Log Groups..."
LOG_GROUPS=$(aws logs describe-log-groups \
    --region $REGION \
    --query "logGroups[?contains(logGroupName, '$PROJECT_TAG')].logGroupName" \
    --output text 2>/dev/null)

for lg in $LOG_GROUPS; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        aws logs delete-log-group \
            --log-group-name "$lg" \
            --region $REGION || true
    fi
done

# 12. Delete Parameter Store parameters
log_info "Step 11: Deleting Parameter Store parameters..."
PARAMETERS=$(aws ssm describe-parameters \
    --region $REGION \
    --query "Parameters[?contains(Name, '$PROJECT_TAG')].Name" \
    --output text 2>/dev/null)

for param in $PARAMETERS; do
    if [ ! -z "$param" ]; then
        log_action "Deleting parameter: $param"
        aws ssm delete-parameter \
            --name "$param" \
            --region $REGION || true
    fi
done

# 13. Check remaining resources
log_info "Step 12: Checking for remaining resources..."
REMAINING=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=$PROJECT_TAG \
    --region $REGION \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text 2>/dev/null | wc -l)

if [ "$REMAINING" -gt 0 ]; then
    log_warn "Found $REMAINING remaining resources:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --query 'ResourceTagMappingList[].[ResourceARN,Tags[?Key==`Name`].Value|[0]]' \
        --output table
else
    log_info "All resources have been deleted successfully! ✅"
fi

log_info "Cleanup complete!"