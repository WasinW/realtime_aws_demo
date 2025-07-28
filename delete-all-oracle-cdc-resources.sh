#!/bin/bash
# delete-all-oracle-cdc-resources.sh - Unified script to delete ALL resources in oracle-cdc-pipeline
# Merged from: delete-remaining-resources.sh, final-cleanup.sh, force-delete-vpc.sh

set -e

# ======================== Configuration ========================
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

# ======================== Functions ========================
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

# Progress indicator
show_progress() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Wait for resource deletion with timeout
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

# Get VPC ID from project tag
get_vpc_id() {
    aws ec2 describe-vpcs \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --region $REGION \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo ""
}

# Count remaining resources
count_remaining_resources() {
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --query 'length(ResourceTagMappingList)' \
        --output text 2>/dev/null || echo "0"
}

# ======================== Safety Check ========================
clear
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║     ⚠️  WARNING: COMPLETE RESOURCE DELETION SCRIPT ⚠️         ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║ This script will DELETE ALL resources tagged with:           ║${NC}"
echo -e "${RED}║ Project = ${YELLOW}$PROJECT_TAG${RED}                       ║${NC}"
echo -e "${RED}║ Region  = ${YELLOW}$REGION${RED}                                  ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║ This includes:                                               ║${NC}"
echo -e "${RED}║ • EKS Clusters      • RDS Instances    • Redshift Clusters  ║${NC}"
echo -e "${RED}║ • MSK Clusters      • EC2 Instances    • Load Balancers     ║${NC}"
echo -e "${RED}║ • VPC & Networking  • Security Groups  • KMS Keys           ║${NC}"
echo -e "${RED}║ • Secrets Manager   • CloudWatch Logs  • S3 Buckets         ║${NC}"
echo -e "${RED}║ • IAM Roles        • And all other associated resources     ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║           THIS ACTION CANNOT BE UNDONE!                      ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Current resources count: $(count_remaining_resources)${NC}"
echo ""
read -p "Type 'DELETE-ALL-RESOURCES' to confirm: " confirm

if [ "$confirm" != "DELETE-ALL-RESOURCES" ]; then
    echo "Cancelled."
    exit 0
fi

log_info "Starting deletion process at $(date)"
log_info "Logging to: $LOG_FILE"

# ======================== Step 1: EKS Clusters ========================
log_section "Step 1: Deleting EKS Clusters"

EKS_CLUSTERS=$(aws eks list-clusters \
    --region $REGION \
    --query "clusters[?contains(@, '$PROJECT_TAG')]" \
    --output text 2>/dev/null)

for cluster in $EKS_CLUSTERS; do
    if [ ! -z "$cluster" ]; then
        log_action "Deleting EKS cluster: $cluster"
        
        # Delete node groups first
        NODE_GROUPS=$(aws eks list-nodegroups \
            --cluster-name $cluster \
            --region $REGION \
            --query 'nodegroups[]' \
            --output text 2>/dev/null)
        
        for ng in $NODE_GROUPS; do
            log_action "Deleting node group: $ng"
            aws eks delete-nodegroup \
                --cluster-name $cluster \
                --nodegroup-name $ng \
                --region $REGION || true
        done
        
        # Wait for node groups to be deleted
        if [ ! -z "$NODE_GROUPS" ]; then
            log_info "Waiting for node groups to be deleted..."
            for ng in $NODE_GROUPS; do
                aws eks wait nodegroup-deleted \
                    --cluster-name $cluster \
                    --nodegroup-name $ng \
                    --region $REGION 2>/dev/null || true
            done
        fi
        
        # Delete Fargate profiles
        FARGATE_PROFILES=$(aws eks list-fargate-profiles \
            --cluster-name $cluster \
            --region $REGION \
            --query 'fargateProfileNames[]' \
            --output text 2>/dev/null)
        
        for fp in $FARGATE_PROFILES; do
            log_action "Deleting Fargate profile: $fp"
            aws eks delete-fargate-profile \
                --cluster-name $cluster \
                --fargate-profile-name $fp \
                --region $REGION || true
        done
        
        # Delete cluster
        aws eks delete-cluster \
            --name $cluster \
            --region $REGION || true
    fi
done

# ======================== Step 2: MSK Clusters ========================
log_section "Step 2: Deleting MSK Clusters"

MSK_CLUSTERS=$(aws kafka list-clusters \
    --region $REGION \
    --query "ClusterInfoList[?contains(ClusterName, '$PROJECT_TAG')].ClusterArn" \
    --output text 2>/dev/null)

for cluster_arn in $MSK_CLUSTERS; do
    if [ ! -z "$cluster_arn" ]; then
        log_action "Deleting MSK cluster: $cluster_arn"
        aws kafka delete-cluster \
            --cluster-arn $cluster_arn \
            --region $REGION || true
    fi
done

# ======================== Step 3: RDS Instances ========================
log_section "Step 3: Deleting RDS Instances"

RDS_INSTANCES=$(aws rds describe-db-instances \
    --region $REGION \
    --query "DBInstances[?contains(DBInstanceIdentifier, '$PROJECT_TAG')].DBInstanceIdentifier" \
    --output text 2>/dev/null)

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

# ======================== Step 4: Redshift Clusters ========================
log_section "Step 4: Deleting Redshift Clusters"

REDSHIFT_CLUSTERS=$(aws redshift describe-clusters \
    --region $REGION \
    --query "Clusters[?contains(ClusterIdentifier, '$PROJECT_TAG')].ClusterIdentifier" \
    --output text 2>/dev/null)

for cluster in $REDSHIFT_CLUSTERS; do
    if [ ! -z "$cluster" ]; then
        log_action "Deleting Redshift cluster: $cluster"
        aws redshift delete-cluster \
            --cluster-identifier $cluster \
            --skip-final-cluster-snapshot \
            --region $REGION || true
    fi
done

# ======================== Step 5: EC2 Instances ========================
log_section "Step 5: Terminating EC2 Instances"

INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=running,stopped" \
    --region $REGION \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null)

for instance in $INSTANCES; do
    if [ ! -z "$instance" ]; then
        log_action "Terminating instance: $instance"
        aws ec2 terminate-instances \
            --instance-ids $instance \
            --region $REGION || true
    fi
done

if [ ! -z "$INSTANCES" ]; then
    log_info "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated \
        --instance-ids $INSTANCES \
        --region $REGION 2>/dev/null || true
fi

# ======================== Step 6: Load Balancers ========================
log_section "Step 6: Deleting Load Balancers"

# ALBs/NLBs
LOAD_BALANCERS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --query "LoadBalancers[?contains(LoadBalancerName, '$PROJECT_TAG')].LoadBalancerArn" \
    --output text 2>/dev/null)

for lb in $LOAD_BALANCERS; do
    if [ ! -z "$lb" ]; then
        log_action "Deleting load balancer: $lb"
        aws elbv2 delete-load-balancer \
            --load-balancer-arn $lb \
            --region $REGION || true
    fi
done

# Classic ELBs
CLASSIC_ELBS=$(aws elb describe-load-balancers \
    --region $REGION \
    --query "LoadBalancerDescriptions[?contains(LoadBalancerName, '$PROJECT_TAG')].LoadBalancerName" \
    --output text 2>/dev/null)

for elb in $CLASSIC_ELBS; do
    if [ ! -z "$elb" ]; then
        log_action "Deleting classic ELB: $elb"
        aws elb delete-load-balancer \
            --load-balancer-name $elb \
            --region $REGION || true
    fi
done

# ======================== Step 7: Auto Scaling Groups ========================
log_section "Step 7: Deleting Auto Scaling Groups"

ASG_GROUPS=$(aws autoscaling describe-auto-scaling-groups \
    --region $REGION \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, '$PROJECT_TAG')].AutoScalingGroupName" \
    --output text 2>/dev/null)

for asg in $ASG_GROUPS; do
    if [ ! -z "$asg" ]; then
        log_action "Deleting ASG: $asg"
        aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name $asg \
            --force-delete \
            --region $REGION || true
    fi
done

# ======================== Step 8: VPC Resources ========================
log_section "Step 8: Deleting VPC and Network Resources"

VPC_ID=$(get_vpc_id)
if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "Found VPC: $VPC_ID"
    
    # 8.1 Delete NAT Gateways
    log_action "Deleting NAT Gateways..."
    NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --region $REGION \
        --query 'NatGateways[].NatGatewayId' \
        --output text 2>/dev/null)
    
    for nat in $NAT_GATEWAYS; do
        if [ ! -z "$nat" ]; then
            aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $REGION || true
        fi
    done
    
    # 8.2 Release Elastic IPs
    log_action "Releasing Elastic IPs..."
    EIPS=$(aws ec2 describe-addresses \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --region $REGION \
        --query 'Addresses[].AllocationId' \
        --output text 2>/dev/null)
    
    for eip in $EIPS; do
        if [ ! -z "$eip" ]; then
            aws ec2 release-address --allocation-id $eip --region $REGION || true
        fi
    done
    
    # 8.3 Delete VPC Endpoints
    log_action "Deleting VPC Endpoints..."
    VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text 2>/dev/null)
    
    for endpoint in $VPC_ENDPOINTS; do
        if [ ! -z "$endpoint" ]; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $REGION || true
        fi
    done
    
    # Wait for endpoints
    if [ ! -z "$VPC_ENDPOINTS" ]; then
        sleep 10
    fi
    
    # 8.4 Detach and Delete Internet Gateway
    log_action "Deleting Internet Gateway..."
    IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text 2>/dev/null)
    
    if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $REGION || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION || true
    fi
    
    # 8.5 Delete Route Tables (non-main)
    log_action "Deleting Route Tables..."
    ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'RouteTables[?Main==`false`].RouteTableId' \
        --output text 2>/dev/null)
    
    for rt in $ROUTE_TABLES; do
        if [ ! -z "$rt" ]; then
            # Disassociate subnets
            ASSOCIATIONS=$(aws ec2 describe-route-tables \
                --route-table-ids $rt \
                --region $REGION \
                --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
                --output text 2>/dev/null)
            
            for assoc in $ASSOCIATIONS; do
                if [ ! -z "$assoc" ]; then
                    aws ec2 disassociate-route-table --association-id $assoc --region $REGION || true
                fi
            done
            
            aws ec2 delete-route-table --route-table-id $rt --region $REGION || true
        fi
    done
    
    # 8.6 Delete Security Groups
    log_action "Deleting Security Groups..."
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text 2>/dev/null)
    
    # First remove all rules
    for sg in $SECURITY_GROUPS; do
        if [ ! -z "$sg" ]; then
            # Remove ingress rules
            aws ec2 describe-security-groups \
                --group-ids $sg \
                --region $REGION \
                --query 'SecurityGroups[0].IpPermissions' \
                --output json 2>/dev/null > /tmp/sg-ingress-$sg.json
            
            if [ -s /tmp/sg-ingress-$sg.json ] && [ "$(cat /tmp/sg-ingress-$sg.json)" != "[]" ]; then
                aws ec2 revoke-security-group-ingress \
                    --group-id $sg \
                    --ip-permissions file:///tmp/sg-ingress-$sg.json \
                    --region $REGION 2>/dev/null || true
            fi
            
            # Remove egress rules
            aws ec2 describe-security-groups \
                --group-ids $sg \
                --region $REGION \
                --query 'SecurityGroups[0].IpPermissionsEgress' \
                --output json 2>/dev/null > /tmp/sg-egress-$sg.json
            
            if [ -s /tmp/sg-egress-$sg.json ] && [ "$(cat /tmp/sg-egress-$sg.json)" != "[]" ]; then
                aws ec2 revoke-security-group-egress \
                    --group-id $sg \
                    --ip-permissions file:///tmp/sg-egress-$sg.json \
                    --region $REGION 2>/dev/null || true
            fi
            
            rm -f /tmp/sg-ingress-$sg.json /tmp/sg-egress-$sg.json
        fi
    done
    
    # Delete security groups
    for sg in $SECURITY_GROUPS; do
        if [ ! -z "$sg" ]; then
            aws ec2 delete-security-group --group-id $sg --region $REGION || true
        fi
    done
    
    # 8.7 Delete Subnets
    log_action "Deleting Subnets..."
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region $REGION \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null)
    
    for subnet in $SUBNETS; do
        if [ ! -z "$subnet" ]; then
            aws ec2 delete-subnet --subnet-id $subnet --region $REGION || true
        fi
    done
    
    # 8.8 Delete VPC
    log_action "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true
fi

# ======================== Step 9: Database Resources ========================
log_section "Step 9: Deleting Database Resources"

# RDS subnet groups
RDS_SUBNET_GROUPS=$(aws rds describe-db-subnet-groups \
    --region $REGION \
    --query "DBSubnetGroups[?contains(DBSubnetGroupName, '$PROJECT_TAG')].DBSubnetGroupName" \
    --output text 2>/dev/null)

for dbsg in $RDS_SUBNET_GROUPS; do
    if [ ! -z "$dbsg" ]; then
        log_action "Deleting RDS subnet group: $dbsg"
        aws rds delete-db-subnet-group --db-subnet-group-name $dbsg --region $REGION || true
    fi
done

# RDS parameter groups
RDS_PARAM_GROUPS=$(aws rds describe-db-parameter-groups \
    --region $REGION \
    --query "DBParameterGroups[?contains(DBParameterGroupName, '$PROJECT_TAG') && !contains(DBParameterGroupName, 'default.')].DBParameterGroupName" \
    --output text 2>/dev/null)

for dbpg in $RDS_PARAM_GROUPS; do
    if [ ! -z "$dbpg" ]; then
        log_action "Deleting RDS parameter group: $dbpg"
        aws rds delete-db-parameter-group --db-parameter-group-name $dbpg --region $REGION || true
    fi
done

# RDS option groups
RDS_OPTION_GROUPS=$(aws rds describe-option-groups \
    --region $REGION \
    --query "OptionGroupsList[?contains(OptionGroupName, '$PROJECT_TAG') && !contains(OptionGroupName, 'default:')].OptionGroupName" \
    --output text 2>/dev/null)

for dbog in $RDS_OPTION_GROUPS; do
    if [ ! -z "$dbog" ]; then
        log_action "Deleting RDS option group: $dbog"
        aws rds delete-option-group --option-group-name $dbog --region $REGION || true
    fi
done

# Redshift subnet groups
REDSHIFT_SUBNET_GROUPS=$(aws redshift describe-cluster-subnet-groups \
    --region $REGION \
    --query "ClusterSubnetGroups[?contains(ClusterSubnetGroupName, '$PROJECT_TAG')].ClusterSubnetGroupName" \
    --output text 2>/dev/null)

for rsg in $REDSHIFT_SUBNET_GROUPS; do
    if [ ! -z "$rsg" ]; then
        log_action "Deleting Redshift subnet group: $rsg"
        aws redshift delete-cluster-subnet-group --cluster-subnet-group-name $rsg --region $REGION || true
    fi
done

# Redshift parameter groups
REDSHIFT_PARAM_GROUPS=$(aws redshift describe-cluster-parameter-groups \
    --region $REGION \
    --query "ParameterGroups[?contains(ParameterGroupName, '$PROJECT_TAG') && !contains(ParameterGroupName, 'default.')].ParameterGroupName" \
    --output text 2>/dev/null)

for rpg in $REDSHIFT_PARAM_GROUPS; do
    if [ ! -z "$rpg" ]; then
        log_action "Deleting Redshift parameter group: $rpg"
        aws redshift delete-cluster-parameter-group --parameter-group-name $rpg --region $REGION || true
    fi
done

# ======================== Step 10: Storage Resources ========================
log_section "Step 10: Deleting Storage Resources"

# S3 buckets
S3_BUCKETS=$(aws s3api list-buckets \
    --query "Buckets[?contains(Name, '$PROJECT_TAG')].Name" \
    --output text 2>/dev/null)

for bucket in $S3_BUCKETS; do
    if [ ! -z "$bucket" ]; then
        log_action "Deleting S3 bucket: $bucket"
        # Delete all objects first
        aws s3 rm s3://$bucket --recursive || true
        # Delete all versions
        aws s3api delete-objects \
            --bucket $bucket \
            --delete "$(aws s3api list-object-versions \
                --bucket $bucket \
                --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
        # Delete bucket
        aws s3api delete-bucket --bucket $bucket --region $REGION || true
    fi
done

# EBS volumes
EBS_VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=status,Values=available" \
    --region $REGION \
    --query 'Volumes[].VolumeId' \
    --output text 2>/dev/null)

for volume in $EBS_VOLUMES; do
    if [ ! -z "$volume" ]; then
        log_action "Deleting EBS volume: $volume"
        aws ec2 delete-volume --volume-id $volume --region $REGION || true
    fi
done

# EBS snapshots
EBS_SNAPSHOTS=$(aws ec2 describe-snapshots \
    --owner-ids self \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Snapshots[].SnapshotId' \
    --output text 2>/dev/null)

for snapshot in $EBS_SNAPSHOTS; do
    if [ ! -z "$snapshot" ]; then
        log_action "Deleting EBS snapshot: $snapshot"
        aws ec2 delete-snapshot --snapshot-id $snapshot --region $REGION || true
    fi
done

# ======================== Step 11: Secrets and Parameters ========================
log_section "Step 11: Deleting Secrets and Parameters"

# Secrets Manager
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

# Parameter Store
PARAMETERS=$(aws ssm describe-parameters \
    --region $REGION \
    --query "Parameters[?contains(Name, '$PROJECT_TAG')].Name" \
    --output text 2>/dev/null)

for param in $PARAMETERS; do
    if [ ! -z "$param" ]; then
        log_action "Deleting parameter: $param"
        aws ssm delete-parameter --name "$param" --region $REGION || true
    fi
done

# ======================== Step 12: CloudWatch Resources ========================
log_section "Step 12: Deleting CloudWatch Resources"

# Log groups
LOG_GROUPS=$(aws logs describe-log-groups \
    --region $REGION \
    --query "logGroups[?contains(logGroupName, '$PROJECT_TAG')].logGroupName" \
    --output text 2>/dev/null)

for lg in $LOG_GROUPS; do
    if [ ! -z "$lg" ]; then
        log_action "Deleting log group: $lg"
        aws logs delete-log-group --log-group-name "$lg" --region $REGION || true
    fi
done

# CloudWatch alarms
CW_ALARMS=$(aws cloudwatch describe-alarms \
    --region $REGION \
    --query "MetricAlarms[?contains(AlarmName, '$PROJECT_TAG')].AlarmName" \
    --output text 2>/dev/null)

for alarm in $CW_ALARMS; do
    if [ ! -z "$alarm" ]; then
        log_action "Deleting alarm: $alarm"
        aws cloudwatch delete-alarms --alarm-names "$alarm" --region $REGION || true
    fi
done

# ======================== Step 13: IAM Resources ========================
log_section "Step 13: Deleting IAM Resources"

# IAM roles
IAM_ROLES=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, '$PROJECT_TAG')].RoleName" \
    --output text 2>/dev/null)

for role in $IAM_ROLES; do
    if [ ! -z "$role" ]; then
        log_action "Deleting IAM role: $role"
        
        # Detach policies
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
            --role-name $role \
            --query 'AttachedPolicies[].PolicyArn' \
            --output text 2>/dev/null)
        
        for policy in $ATTACHED_POLICIES; do
            aws iam detach-role-policy --role-name $role --policy-arn $policy || true
        done
        
        # Delete inline policies
        INLINE_POLICIES=$(aws iam list-role-policies \
            --role-name $role \
            --query 'PolicyNames[]' \
            --output text 2>/dev/null)
        
        for policy in $INLINE_POLICIES; do
            aws iam delete-role-policy --role-name $role --policy-name $policy || true
        done
        
        # Remove from instance profiles
        INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role \
            --role-name $role \
            --query 'InstanceProfiles[].InstanceProfileName' \
            --output text 2>/dev/null)
        
        for profile in $INSTANCE_PROFILES; do
            aws iam remove-role-from-instance-profile \
                --instance-profile-name $profile \
                --role-name $role || true
        done
        
        # Delete role
        aws iam delete-role --role-name $role || true
    fi
done

# IAM policies
IAM_POLICIES=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?contains(PolicyName, '$PROJECT_TAG')].Arn" \
    --output text 2>/dev/null)

for policy in $IAM_POLICIES; do
    if [ ! -z "$policy" ]; then
        log_action "Deleting IAM policy: $policy"
        
        # Delete all versions except default
        VERSIONS=$(aws iam list-policy-versions \
            --policy-arn $policy \
            --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
            --output text 2>/dev/null)
        
        for version in $VERSIONS; do
            aws iam delete-policy-version --policy-arn $policy --version-id $version || true
        done
        
        aws iam delete-policy --policy-arn $policy || true
    fi
done

# Instance profiles
INSTANCE_PROFILES=$(aws iam list-instance-profiles \
    --query "InstanceProfiles[?contains(InstanceProfileName, '$PROJECT_TAG')].InstanceProfileName" \
    --output text 2>/dev/null)

for profile in $INSTANCE_PROFILES; do
    if [ ! -z "$profile" ]; then
        log_action "Deleting instance profile: $profile"
        aws iam delete-instance-profile --instance-profile-name $profile || true
    fi
done

# ======================== Step 14: KMS Keys ========================
log_section "Step 14: Scheduling KMS Keys for Deletion"

KMS_KEYS=$(aws kms list-keys \
    --region $REGION \
    --query 'Keys[].KeyId' \
    --output text 2>/dev/null)

for key_id in $KMS_KEYS; do
    if [ ! -z "$key_id" ]; then
        # Check if key has our project tag
        KEY_TAGS=$(aws kms list-resource-tags \
            --key-id $key_id \
            --region $REGION \
            --query "Tags[?TagKey=='Project' && TagValue=='$PROJECT_TAG'].TagKey" \
            --output text 2>/dev/null || echo "")
        
        if [ ! -z "$KEY_TAGS" ]; then
            # Check if key is already scheduled for deletion
            KEY_STATE=$(aws kms describe-key \
                --key-id $key_id \
                --region $REGION \
                --query 'KeyMetadata.KeyState' \
                --output text 2>/dev/null)
            
            if [ "$KEY_STATE" != "PendingDeletion" ]; then
                log_action "Scheduling KMS key for deletion: $key_id"
                aws kms schedule-key-deletion \
                    --key-id $key_id \
                    --pending-window-in-days 7 \
                    --region $REGION || true
            fi
        fi
    fi
done

# ======================== Step 15: Final Check ========================
log_section "Final Resource Check"

REMAINING=$(count_remaining_resources)
log_info "Remaining resources with tag Project=$PROJECT_TAG: $REMAINING"

if [ "$REMAINING" -gt 0 ]; then
    log_warn "Some resources still remain:"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --output table | tee -a $LOG_FILE
    
    # Check for KMS keys specifically
    KMS_PENDING=$(aws kms list-keys \
        --region $REGION \
        --query 'Keys[].KeyId' \
        --output text | while read key_id; do
            KEY_STATE=$(aws kms describe-key \
                --key-id $key_id \
                --region $REGION \
                --query 'KeyMetadata.KeyState' \
                --output text 2>/dev/null)
            if [ "$KEY_STATE" == "PendingDeletion" ]; then
                aws kms list-resource-tags \
                    --key-id $key_id \
                    --region $REGION \
                    --query "Tags[?TagKey=='Project' && TagValue=='$PROJECT_TAG'].TagKey" \
                    --output text 2>/dev/null
            fi
        done | wc -l)
    
    if [ "$KMS_PENDING" -gt 0 ]; then
        log_info "Note: $KMS_PENDING KMS keys are scheduled for deletion (7-day waiting period)"
    fi
else
    log_info "✅ All resources have been successfully deleted!"
fi

# ======================== Summary ========================
echo ""
log_section "Deletion Summary"
log_info "Process completed at $(date)"
log_info "Log file: $LOG_FILE"
log_info "Total remaining resources: $REMAINING"

if [ "$REMAINING" -eq 0 ] || ([ "$REMAINING" -le 5 ] && [ "$KMS_PENDING" -gt 0 ]); then
    echo -e "\n${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✅ DELETION COMPLETED SUCCESSFULLY! ✅${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
else
    echo -e "\n${YELLOW}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}   ⚠️  Some resources may still remain${NC}"
    echo -e "${YELLOW}   Check the log file for details${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
fi