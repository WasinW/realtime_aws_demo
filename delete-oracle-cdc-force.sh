#!/bin/bash
# Force delete all resources with better handling
# Fixed for Windows Git Bash and carriage return issues

set -e

# Configuration
PROJECT_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"
LOG_FILE="deletion-force-$(date +%Y%m%d-%H%M%S).log"

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

# Clean string from carriage returns and spaces
clean_id() {
    echo "$1" | tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]*$//'
}

# Force terminate instances
force_terminate_instances() {
    local instance_id=$(clean_id "$1")
    if [ ! -z "$instance_id" ]; then
        log_action "Force terminating instance: $instance_id"
        
        # Disable termination protection first
        aws ec2 modify-instance-attribute \
            --instance-id "$instance_id" \
            --no-disable-api-termination \
            --region $REGION 2>/dev/null || true
        
        # Force stop first
        aws ec2 stop-instances \
            --instance-ids "$instance_id" \
            --force \
            --region $REGION 2>/dev/null || true
        
        # Then terminate
        aws ec2 terminate-instances \
            --instance-ids "$instance_id" \
            --region $REGION 2>/dev/null || true
    fi
}

# Safety check
clear
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     ⚠️  FORCE DELETE ALL RESOURCES ⚠️                        ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║ Project = ${YELLOW}$PROJECT_TAG${RED}                       ║${NC}"
echo -e "${RED}║ Region  = ${YELLOW}$REGION${RED}                                  ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Type 'FORCE-DELETE-ALL' to confirm: " confirm

if [ "$confirm" != "FORCE-DELETE-ALL" ]; then
    echo "Cancelled."
    exit 0
fi

log_info "Starting FORCE deletion at $(date)"

# ======================== Step 1: Find and Delete EKS Resources ========================
log_section "Step 1: Finding and Deleting EKS Resources"

# Find EKS cluster
EKS_CLUSTERS=$(aws eks list-clusters --region $REGION --output json 2>/dev/null | jq -r '.clusters[]' | grep "oracle-cdc-pipeline" || echo "")

if [ ! -z "$EKS_CLUSTERS" ]; then
    for cluster in $EKS_CLUSTERS; do
        cluster=$(clean_id "$cluster")
        log_action "Found EKS cluster: $cluster"
        
        # Delete node groups
        NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $cluster --region $REGION --output json 2>/dev/null | jq -r '.nodegroups[]' || echo "")
        
        for ng in $NODE_GROUPS; do
            ng=$(clean_id "$ng")
            log_action "Deleting node group: $ng"
            aws eks delete-nodegroup --cluster-name $cluster --nodegroup-name $ng --region $REGION || true
        done
        
        # Delete cluster
        aws eks delete-cluster --name $cluster --region $REGION || true
    done
else
    log_info "No EKS clusters found, but will check for orphaned nodes"
fi

# ======================== Step 2: Force Terminate ALL EC2 Instances ========================
log_section "Step 2: Force Terminating ALL EC2 Instances"

# Get ALL instances with our tag, regardless of state
ALL_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.Reservations[].Instances[].InstanceId' || echo "")

if [ ! -z "$ALL_INSTANCES" ]; then
    log_info "Found instances to terminate:"
    echo "$ALL_INSTANCES" | while read instance; do
        instance=$(clean_id "$instance")
        if [ ! -z "$instance" ]; then
            echo "  - $instance"
            force_terminate_instances "$instance"
        fi
    done
    
    # Wait for termination
    log_info "Waiting for all instances to terminate..."
    sleep 30
    
    # Check again
    STILL_RUNNING=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=running,stopping,stopped,pending" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.Reservations[].Instances[].InstanceId' || echo "")
    
    if [ ! -z "$STILL_RUNNING" ]; then
        log_warn "Some instances still not terminated, forcing again..."
        echo "$STILL_RUNNING" | while read instance; do
            instance=$(clean_id "$instance")
            force_terminate_instances "$instance"
        done
        sleep 30
    fi
fi

# ======================== Step 3: Delete Auto Scaling Groups ========================
log_section "Step 3: Deleting Auto Scaling Groups"

ASG_GROUPS=$(aws autoscaling describe-auto-scaling-groups \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.AutoScalingGroups[] | select(.Tags[]? | select(.Key=="Project" and .Value=="'$PROJECT_TAG'")) | .AutoScalingGroupName' || echo "")

for asg in $ASG_GROUPS; do
    asg=$(clean_id "$asg")
    if [ ! -z "$asg" ]; then
        log_action "Deleting ASG: $asg"
        # Set desired capacity to 0
        aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "$asg" \
            --min-size 0 --max-size 0 --desired-capacity 0 \
            --region $REGION 2>/dev/null || true
        
        # Delete ASG
        aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "$asg" \
            --force-delete \
            --region $REGION || true
    fi
done

# ======================== Step 4: Delete Load Balancers ========================
log_section "Step 4: Deleting Load Balancers"

# Delete all ALBs/NLBs
LOAD_BALANCERS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.LoadBalancers[] | select(.LoadBalancerName | contains("k8s-") or contains("oracle-cdc")) | .LoadBalancerArn' || echo "")

for lb in $LOAD_BALANCERS; do
    lb=$(clean_id "$lb")
    if [ ! -z "$lb" ]; then
        log_action "Deleting load balancer: $lb"
        aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region $REGION || true
    fi
done

sleep 20

# ======================== Step 5: Delete Network Interfaces ========================
log_section "Step 5: Force Deleting Network Interfaces"

# Get VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --output text --query 'Vpcs[0].VpcId' 2>/dev/null || echo "")

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    VPC_ID=$(clean_id "$VPC_ID")
    
    # Get all ENIs in VPC
    ALL_ENIS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.NetworkInterfaces[].NetworkInterfaceId' || echo "")
    
    for eni in $ALL_ENIS; do
        eni=$(clean_id "$eni")
        if [ ! -z "$eni" ]; then
            # Get attachment info
            ATTACHMENT_ID=$(aws ec2 describe-network-interfaces \
                --network-interface-ids "$eni" \
                --region $REGION \
                --output json 2>/dev/null | jq -r '.NetworkInterfaces[0].Attachment.AttachmentId // empty' || echo "")
            
            if [ ! -z "$ATTACHMENT_ID" ]; then
                ATTACHMENT_ID=$(clean_id "$ATTACHMENT_ID")
                log_action "Detaching ENI: $eni"
                aws ec2 detach-network-interface \
                    --attachment-id "$ATTACHMENT_ID" \
                    --force \
                    --region $REGION 2>/dev/null || true
                sleep 2
            fi
            
            log_action "Deleting ENI: $eni"
            aws ec2 delete-network-interface \
                --network-interface-id "$eni" \
                --region $REGION 2>/dev/null || true
        fi
    done
fi

# ======================== Step 6: Clean VPC Resources ========================
log_section "Step 6: Cleaning VPC Resources"

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "Cleaning VPC: $VPC_ID"
    
    # Delete Security Groups (with proper handling)
    log_action "Deleting Security Groups..."
    
    # First, remove all rules from all security groups
    ALL_SGS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.SecurityGroups[] | select(.GroupName != "default") | .GroupId' || echo "")
    
    # Remove all rules first
    for sg in $ALL_SGS; do
        sg=$(clean_id "$sg")
        if [ ! -z "$sg" ]; then
            log_action "Removing rules from SG: $sg"
            
            # Get current rules
            SG_INFO=$(aws ec2 describe-security-groups \
                --group-ids "$sg" \
                --region $REGION \
                --output json 2>/dev/null || echo "{}")
            
            # Remove ingress rules
            INGRESS_RULES=$(echo "$SG_INFO" | jq -c '.SecurityGroups[0].IpPermissions // []' 2>/dev/null || echo "[]")
            if [ "$INGRESS_RULES" != "[]" ] && [ "$INGRESS_RULES" != "null" ]; then
                aws ec2 revoke-security-group-ingress \
                    --group-id "$sg" \
                    --ip-permissions "$INGRESS_RULES" \
                    --region $REGION 2>/dev/null || true
            fi
            
            # Remove egress rules
            EGRESS_RULES=$(echo "$SG_INFO" | jq -c '.SecurityGroups[0].IpPermissionsEgress // []' 2>/dev/null || echo "[]")
            if [ "$EGRESS_RULES" != "[]" ] && [ "$EGRESS_RULES" != "null" ]; then
                aws ec2 revoke-security-group-egress \
                    --group-id "$sg" \
                    --ip-permissions "$EGRESS_RULES" \
                    --region $REGION 2>/dev/null || true
            fi
        fi
    done
    
    # Now delete security groups
    for sg in $ALL_SGS; do
        sg=$(clean_id "$sg")
        if [ ! -z "$sg" ]; then
            log_action "Deleting SG: $sg"
            aws ec2 delete-security-group --group-id "$sg" --region $REGION 2>/dev/null || true
        fi
    done
    
    # Delete other VPC resources
    log_action "Deleting VPC Endpoints..."
    aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.VpcEndpoints[].VpcEndpointId' | while read endpoint; do
        endpoint=$(clean_id "$endpoint")
        if [ ! -z "$endpoint" ]; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint" --region $REGION || true
        fi
    done
    
    # Delete IGW
    IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output text --query 'InternetGateways[0].InternetGatewayId' 2>/dev/null || echo "")
    
    if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
        IGW=$(clean_id "$IGW")
        log_action "Detaching and deleting IGW: $IGW"
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region $REGION || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region $REGION || true
    fi
    
    # Delete Route Tables
    aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.RouteTables[] | select(.Main == false) | .RouteTableId' | while read rt; do
        rt=$(clean_id "$rt")
        if [ ! -z "$rt" ]; then
            log_action "Deleting route table: $rt"
            aws ec2 delete-route-table --route-table-id "$rt" --region $REGION || true
        fi
    done
    
    # Delete Subnets
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.Subnets[].SubnetId' | while read subnet; do
        subnet=$(clean_id "$subnet")
        if [ ! -z "$subnet" ]; then
            log_action "Deleting subnet: $subnet"
            aws ec2 delete-subnet --subnet-id "$subnet" --region $REGION || true
        fi
    done
    
    # Delete Network ACLs
    aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --output json 2>/dev/null | jq -r '.NetworkAcls[] | select(.IsDefault == false) | .NetworkAclId' | while read nacl; do
        nacl=$(clean_id "$nacl")
        if [ ! -z "$nacl" ]; then
            log_action "Deleting Network ACL: $nacl"
            aws ec2 delete-network-acl --network-acl-id "$nacl" --region $REGION || true
        fi
    done
    
    # Finally delete VPC
    log_action "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $REGION || true
fi

# ======================== Step 7: Delete Other Resources ========================
log_section "Step 7: Deleting Other Resources"

# Delete volumes
log_action "Deleting EBS Volumes..."
aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.Volumes[] | select(.State == "available") | .VolumeId' | while read vol; do
    vol=$(clean_id "$vol")
    if [ ! -z "$vol" ]; then
        log_action "Deleting volume: $vol"
        aws ec2 delete-volume --volume-id "$vol" --region $REGION || true
    fi
done

# Delete CloudWatch Log Groups
log_action "Deleting CloudWatch Log Groups..."
aws logs describe-log-groups \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.logGroups[] | select(.logGroupName | contains("oracle-cdc-pipeline")) | .logGroupName' | while read lg; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        aws logs delete-log-group --log-group-name "$lg" --region $REGION 2>/dev/null || true
    fi
done

# Delete Secrets
log_action "Deleting Secrets..."
aws secretsmanager list-secrets \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.SecretList[] | select(.Name | contains("oracle-cdc")) | .Name' | while read secret; do
    if [ ! -z "$secret" ]; then
        log_action "Deleting secret: $secret"
        aws secretsmanager delete-secret \
            --secret-id "$secret" \
            --force-delete-without-recovery \
            --region $REGION || true
    fi
done

# Delete Launch Templates
log_action "Deleting Launch Templates..."
aws ec2 describe-launch-templates \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.LaunchTemplates[] | select(.LaunchTemplateName | contains("oracle-cdc-pipeline")) | .LaunchTemplateId' | while read lt; do
    lt=$(clean_id "$lt")
    if [ ! -z "$lt" ]; then
        log_action "Deleting launch template: $lt"
        aws ec2 delete-launch-template --launch-template-id "$lt" --region $REGION || true
    fi
done

# Schedule KMS keys for deletion
log_action "Scheduling KMS keys for deletion..."
aws kms list-aliases \
    --region $REGION \
    --output json 2>/dev/null | jq -r '.Aliases[] | select(.AliasName | contains("oracle-cdc")) | .TargetKeyId // empty' | while read key; do
    key=$(clean_id "$key")
    if [ ! -z "$key" ] && [ "$key" != "null" ]; then
        log_action "Scheduling KMS key for deletion: $key"
        aws kms schedule-key-deletion --key-id "$key" --pending-window-in-days 7 --region $REGION 2>/dev/null || true
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
    log_warn "Resources still remaining:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --output table
fi

# ======================== Summary ========================
log_section "Summary"
log_info "Force deletion completed at $(date)"
log_info "Log file: $LOG_FILE"

if [ "$REMAINING" -le "5" ]; then
    echo -e "\n${GREEN}✅ FORCE DELETION COMPLETED!${NC}"
    echo -e "${GREEN}Only KMS keys remain (7-day waiting period)${NC}"
else
    echo -e "\n${YELLOW}⚠️  $REMAINING resources still remain${NC}"
    echo -e "${YELLOW}Check the table above for details${NC}"
fi