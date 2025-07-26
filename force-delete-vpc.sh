#!/bin/bash
# force-delete-vpc.sh - Force delete VPC and all dependencies

set -e

PROJECT_TAG="oracle-cdc-pipeline"
REGION="ap-southeast-1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}=== FORCE DELETE VPC AND ALL DEPENDENCIES ===${NC}"
echo "This will delete ALL resources associated with VPC"
read -p "Type 'FORCE-DELETE' to continue: " confirm
if [ "$confirm" != "FORCE-DELETE" ]; then
    exit 0
fi

# Find VPC
echo -e "\n${GREEN}Finding VPC...${NC}"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --region $REGION \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    echo "No VPC found"
    exit 1
fi

echo "Found VPC: $VPC_ID"

# Delete in specific order
echo -e "\n${YELLOW}1. Terminating EC2 instances...${NC}"
INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped" \
    --region $REGION \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

for instance in $INSTANCES; do
    echo "Terminating: $instance"
    aws ec2 terminate-instances --instance-ids $instance --region $REGION || true
done

if [ ! -z "$INSTANCES" ]; then
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCES --region $REGION || true
fi

echo -e "\n${YELLOW}2. Deleting Load Balancers...${NC}"
# Delete ALBs/NLBs
for lb in $(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text); do
    echo "Deleting LB: $lb"
    aws elbv2 delete-load-balancer --load-balancer-arn $lb --region $REGION || true
done

echo -e "\n${YELLOW}3. Deleting NAT Gateways...${NC}"
for nat in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text); do
    echo "Deleting NAT: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $REGION || true
done

echo -e "\n${YELLOW}4. Releasing Elastic IPs...${NC}"
for eip in $(aws ec2 describe-addresses --region $REGION --query "Addresses[?Domain=='vpc'].AllocationId" --output text); do
    echo "Releasing EIP: $eip"
    aws ec2 release-address --allocation-id $eip --region $REGION || true
done

echo -e "\n${YELLOW}5. Deleting VPC Endpoints...${NC}"
for endpoint in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    echo "Deleting endpoint: $endpoint"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $REGION || true
done

echo -e "\n${YELLOW}6. Detaching Internet Gateway...${NC}"
IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ "$IGW" != "None" ] && [ ! -z "$IGW" ]; then
    echo "Detaching and deleting IGW: $IGW"
    aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $REGION || true
    aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $REGION || true
fi

echo -e "\n${YELLOW}7. Deleting Security Group Rules...${NC}"
# Remove all rules from security groups first
for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
    echo "Cleaning SG: $sg"
    # Remove all ingress rules
    aws ec2 revoke-security-group-ingress --group-id $sg --region $REGION \
        --ip-permissions "$(aws ec2 describe-security-groups --group-id $sg --region $REGION --query 'SecurityGroups[0].IpPermissions')" 2>/dev/null || true
    # Remove all egress rules  
    aws ec2 revoke-security-group-egress --group-id $sg --region $REGION \
        --ip-permissions "$(aws ec2 describe-security-groups --group-id $sg --region $REGION --query 'SecurityGroups[0].IpPermissionsEgress')" 2>/dev/null || true
done

echo -e "\n${YELLOW}8. Deleting Security Groups...${NC}"
# Delete security groups
for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
    echo "Deleting SG: $sg"
    aws ec2 delete-security-group --group-id $sg --region $REGION || true
done

echo -e "\n${YELLOW}9. Deleting Subnets...${NC}"
for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'Subnets[].SubnetId' --output text); do
    echo "Deleting subnet: $subnet"
    aws ec2 delete-subnet --subnet-id $subnet --region $REGION || true
done

echo -e "\n${YELLOW}10. Deleting Route Tables...${NC}"
for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'RouteTables[?Main==`false`].RouteTableId' --output text); do
    echo "Deleting RT: $rt"
    aws ec2 delete-route-table --route-table-id $rt --region $REGION || true
done

echo -e "\n${YELLOW}11. Deleting VPC...${NC}"
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true

echo -e "\n${YELLOW}12. Deleting Secrets...${NC}"
for secret in $(aws secretsmanager list-secrets --region $REGION --query "SecretList[?contains(Name, '$PROJECT_TAG')].Name" --output text); do
    echo "Deleting secret: $secret"
    aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region $REGION || true
done

echo -e "\n${YELLOW}13. Deleting RDS Resources...${NC}"
# Delete DB subnet groups
for dbsg in $(aws rds describe-db-subnet-groups --region $REGION --query "DBSubnetGroups[?contains(DBSubnetGroupName, '$PROJECT_TAG')].DBSubnetGroupName" --output text); do
    echo "Deleting DB subnet group: $dbsg"
    aws rds delete-db-subnet-group --db-subnet-group-name $dbsg --region $REGION || true
done

# Delete DB parameter groups
for dbpg in $(aws rds describe-db-parameter-groups --region $REGION --query "DBParameterGroups[?contains(DBParameterGroupName, '$PROJECT_TAG')].DBParameterGroupName" --output text); do
    echo "Deleting DB parameter group: $dbpg"
    aws rds delete-db-parameter-group --db-parameter-group-name $dbpg --region $REGION || true
done

# Delete DB option groups
for dbog in $(aws rds describe-option-groups --region $REGION --query "OptionGroupsList[?contains(OptionGroupName, '$PROJECT_TAG')].OptionGroupName" --output text); do
    echo "Deleting DB option group: $dbog"
    aws rds delete-option-group --option-group-name $dbog --region $REGION || true
done

echo -e "\n${YELLOW}14. Deleting Redshift Resources...${NC}"
# Delete Redshift subnet groups
for rsg in $(aws redshift describe-cluster-subnet-groups --region $REGION --query "ClusterSubnetGroups[?contains(ClusterSubnetGroupName, '$PROJECT_TAG')].ClusterSubnetGroupName" --output text); do
    echo "Deleting Redshift subnet group: $rsg"
    aws redshift delete-cluster-subnet-group --cluster-subnet-group-name $rsg --region $REGION || true
done

# Delete Redshift parameter groups
for rpg in $(aws redshift describe-cluster-parameter-groups --region $REGION --query "ParameterGroups[?contains(ParameterGroupName, '$PROJECT_TAG')].ParameterGroupName" --output text); do
    echo "Deleting Redshift parameter group: $rpg"
    aws redshift delete-cluster-parameter-group --parameter-group-name $rpg --region $REGION || true
done

echo -e "\n${GREEN}=== FINAL CHECK ===${NC}"
REMAINING=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=Project,Values=$PROJECT_TAG \
    --region $REGION \
    --output json | jq '.ResourceTagMappingList | length')

echo "Remaining resources: $REMAINING"

if [ "$REMAINING" -gt 0 ]; then
    echo -e "\n${YELLOW}Remaining resources:${NC}"
    aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Project,Values=$PROJECT_TAG \
        --region $REGION \
        --output table
else
    echo -e "\n${GREEN}✅ All resources deleted successfully!${NC}"
fi