# CDC Pipeline Service Management Guide

## Quick Reference Commands

### 🟢 Start Services
```bash
# Start EKS Nodes
aws eks update-nodegroup-config \
  --cluster-name oracle-cdc-pipeline-demo-eks \
  --nodegroup-name debezium \
  --scaling-config minSize=1,maxSize=3,desiredSize=2

# Start RDS
aws rds start-db-instance \
  --db-instance-identifier oracle-cdc-pipeline-demo-oracle

# Resume Redshift
aws redshift resume-cluster \
  --cluster-identifier oracle-cdc-pipeline-demo-redshift

# Start Kubernetes workloads
kubectl scale deployment --all --replicas=3 -n kafka
```

### 🔴 Stop Services
```bash
# Stop EKS Nodes
aws eks update-nodegroup-config \
  --cluster-name oracle-cdc-pipeline-demo-eks \
  --nodegroup-name debezium \
  --scaling-config minSize=0,maxSize=0,desiredSize=0

# Stop RDS
aws rds stop-db-instance \
  --db-instance-identifier oracle-cdc-pipeline-demo-oracle

# Pause Redshift  
aws redshift pause-cluster \
  --cluster-identifier oracle-cdc-pipeline-demo-redshift
```

### 🔄 Recreate Specific Services

#### Recreate MSK Cluster
```bash
# Option 1: Using taint
terraform taint module.msk.aws_msk_cluster.main
terraform apply

# Option 2: Using replace
terraform apply -replace="module.msk.aws_msk_cluster.main"

# Option 3: Target destroy/create
terraform destroy -target=module.msk
terraform apply -target=module.msk
```

#### Recreate RDS Instance
```bash
# ⚠️ Warning: This will delete data!
# 1. Backup first
aws rds create-db-snapshot \
  --db-instance-identifier oracle-cdc-pipeline-demo-oracle \
  --db-snapshot-identifier oracle-backup-$(date +%Y%m%d-%H%M%S)

# 2. Recreate
terraform apply -replace="module.rds.aws_db_instance.oracle"
```

#### Recreate EKS Node Group
```bash
# Safe - no data loss
terraform apply -replace="module.eks.aws_eks_node_group.main['debezium']"
```

### 📊 Cost Optimization Scenarios

#### Scenario 1: Overnight/Weekend Shutdown
```bash
# Friday evening
./stop-all-services.sh

# Monday morning
./start-all-services.sh
```

#### Scenario 2: Keep Only Data Services
```bash
# Stop compute, keep storage
aws eks update-nodegroup-config --scaling-config desiredSize=0
# Keep RDS and Redshift running
```

#### Scenario 3: Development Pause
```bash
# Stop everything except networking
terraform destroy -target=module.eks -target=module.msk -target=module.rds -target=module.redshift
# Recreate when needed
terraform apply
```

### 🛠️ Terraform State Management

#### Check What Will Be Recreated
```bash
# Dry run
terraform plan -replace="module.msk.aws_msk_cluster.main"

# Show current state
terraform show | grep -A5 "msk_cluster"

# List all resources
terraform state list
```

#### Move Resources Between Modules
```bash
# If refactoring
terraform state mv module.old_name module.new_name
```

#### Remove from State (keep in AWS)
```bash
# Remove from Terraform management
terraform state rm module.msk.aws_msk_cluster.main
```

### ⚠️ Important Notes

1. **MSK Cannot be Stopped** - Only destroyed
   - Cost continues even if unused
   - Consider destroying if not needed

2. **RDS Auto-Start After 7 Days**
   - Set reminder to stop again
   - Or use Lambda to auto-stop

3. **EKS Control Plane Always Costs**
   - $0.10/hour cannot be avoided
   - Unless you destroy entire cluster

4. **Data Persistence**
   - EBS volumes persist when instances stop
   - S3 data persists always
   - Backup before destroying RDS/Redshift

### 📱 Mobile App Commands (AWS CLI on phone)
```bash
# Quick status check
aws eks describe-nodegroup \
  --cluster-name oracle-cdc-pipeline-demo-eks \
  --nodegroup-name debezium \
  --query 'nodegroup.scalingConfig'

# Emergency stop all
aws eks update-nodegroup-config --scaling-config desiredSize=0
aws rds stop-db-instance --db-instance-identifier oracle-cdc-pipeline-demo-oracle
aws redshift pause-cluster --cluster-identifier oracle-cdc-pipeline-demo-redshift
```