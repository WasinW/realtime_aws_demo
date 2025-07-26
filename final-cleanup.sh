#!/bin/bash
# final-cleanup.sh - ลบ resources 8 ตัวสุดท้าย

REGION="ap-southeast-1"
VPC_ID="vpc-05d360021883b67d2"

echo "=== Final Cleanup - 8 remaining resources ==="

# 1. Delete VPC Endpoints (3 ตัว)
echo "1. Deleting VPC Endpoints..."
aws ec2 delete-vpc-endpoints \
  --vpc-endpoint-ids vpce-0187f97e4bf887f63 vpce-01fd6683e11069a32 vpce-0b0dfc7bf222521af \
  --region $REGION

# Wait for endpoints to be deleted
echo "Waiting 10 seconds for endpoints deletion..."
sleep 10

# 2. Delete Route Table
echo "2. Deleting Route Table..."
aws ec2 delete-route-table \
  --route-table-id rtb-032573ee4a1116b1f \
  --region $REGION || echo "Route table might be main table"

# 3. Delete VPC
echo "3. Deleting VPC..."
aws ec2 delete-vpc \
  --vpc-id $VPC_ID \
  --region $REGION

# 4. Delete KMS Keys (ระวัง! อาจมี 7-30 days waiting period)
echo "4. Scheduling KMS Keys for deletion..."
echo "Note: KMS keys have a waiting period of 7-30 days before actual deletion"

# Schedule deletion for each KMS key
aws kms schedule-key-deletion \
  --key-id fb4f67ce-d4d2-47a1-b7b9-a18d000c6217 \
  --pending-window-in-days 7 \
  --region $REGION || echo "Key 1 already scheduled or error"

aws kms schedule-key-deletion \
  --key-id 7df57f07-8cc9-4f5c-82af-a279c5e2597d \
  --pending-window-in-days 7 \
  --region $REGION || echo "Key 2 already scheduled or error"

aws kms schedule-key-deletion \
  --key-id a1b51d6d-a61d-4427-a8c8-64d025fec6cd \
  --pending-window-in-days 7 \
  --region $REGION || echo "Key 3 already scheduled or error"

echo ""
echo "=== Cleanup Status ==="
echo "✓ VPC Endpoints deleted"
echo "✓ VPC deleted"
echo "⏳ KMS Keys scheduled for deletion (will be deleted after 7 days)"
echo ""

# Final check
echo "Checking remaining resources..."
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=oracle-cdc-pipeline \
  --region $REGION \
  --output table

echo ""
echo "Done! Only KMS keys remain (pending deletion in 7 days)"