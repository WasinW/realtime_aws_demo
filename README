# Makefile
.PHONY: help init deploy destroy test clean

TERRAFORM_DIR = terraform/environments/demo
PYTHON = python3
AWS_REGION ?= ap-southeast-1

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Initialize Terraform backend
	@echo "Initializing Terraform backend..."
	@bash scripts/setup/01-init-terraform-backend.sh

deploy: ## Deploy all infrastructure
	@echo "Deploying infrastructure..."
	@cd $(TERRAFORM_DIR) && terraform init && terraform apply -auto-approve

plan: ## Show Terraform plan
	@cd $(TERRAFORM_DIR) && terraform plan

destroy: ## Destroy all infrastructure
	@echo "WARNING: This will destroy all infrastructure!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		cd $(TERRAFORM_DIR) && terraform destroy -auto-approve; \
	fi

setup-k8s: ## Configure kubectl and install operators
	@bash scripts/setup/03-configure-kubectl.sh
	@bash scripts/setup/04-install-strimzi.sh
	@bash scripts/setup/05-create-secrets.sh

deploy-debezium: ## Deploy Debezium connector
	@bash scripts/setup/06-deploy-debezium.sh

test-producer: ## Run test data producer
	@cd applications/kafka-producer && \
	$(PYTHON) producer.py --cluster-arn $$(cd ../../$(TERRAFORM_DIR) && terraform output -raw msk_cluster_arn)

test-consumer: ## Run test consumer
	@cd applications/kafka-consumer && \
	$(PYTHON) consumer.py --cluster-arn $$(cd ../../$(TERRAFORM_DIR) && terraform output -raw msk_cluster_arn) \
		--topics oracle.inventory.customers oracle.inventory.products oracle.inventory.orders

install-deps: ## Install Python dependencies
	@pip install -r applications/kafka-producer/requirements.txt
	@pip install -r applications/kafka-consumer/requirements.txt

clean: ## Clean up temporary files
	@find . -type d -name "__pycache__" -exec rm -rf {} +
	@find . -type f -name "*.pyc" -delete
	@rm -f $(TERRAFORM_DIR)/tfplan
	@rm -f $(TERRAFORM_DIR)/outputs.json

validate: ## Validate Terraform configuration
	@cd $(TERRAFORM_DIR) && terraform fmt -check && terraform validate

format: ## Format Terraform files
	@cd $(TERRAFORM_DIR) && terraform fmt -recursive

cost-estimate: ## Estimate monthly costs
	@echo "Estimated Monthly Costs (Demo Environment):"
	@echo "- MSK (3 brokers m5.large): ~$$450"
	@echo "- EKS (3 nodes m5.xlarge): ~$$400"
	@echo "- RDS Oracle (db.m5.xlarge): ~$$600"
	@echo "- Redshift (2 nodes dc2.large): ~$$360"
	@echo "- NAT Gateways (3 AZs): ~$$135"
	@echo "- Data Transfer: ~$$100"
	@echo "Total: ~$$2,045/month"

---

# Oracle CDC Pipeline to Redshift

A production-ready Change Data Capture (CDC) pipeline that streams data from Oracle to Redshift using MSK (Managed Streaming for Kafka), Debezium, and Redshift Streaming Ingestion.

## 🏗️ Architecture Overview

```
Oracle DB → Debezium (EKS) → MSK → PII Masking → Redshift Streaming
```

### Key Components:
- **Oracle Database** (RDS): Source database with CDC enabled
- **Debezium on EKS**: Captures changes using Oracle LogMiner
- **Amazon MSK**: Managed Kafka for reliable message streaming
- **PII Masking**: Real-time data masking using Kafka Streams
- **Redshift**: Target data warehouse with streaming ingestion

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0
- kubectl
- Python 3.8+
- jq

### 1. Initialize Backend
```bash
make init
```

### 2. Deploy Infrastructure
```bash
make deploy
```

### 3. Configure Kubernetes
```bash
make setup-k8s
```

### 4. Deploy Debezium
```bash
make deploy-debezium
```

### 5. Test the Pipeline
```bash
# Terminal 1: Start producer
make test-producer

# Terminal 2: Start consumer
make test-consumer
```

## 📊 Project Structure

```
oracle-cdc-pipeline/
├── terraform/           # Infrastructure as Code
│   ├── modules/        # Reusable Terraform modules
│   └── environments/   # Environment-specific configs
├── kubernetes/         # K8s manifests
├── applications/       # Application code
│   ├── kafka-producer/ # Test data generator
│   ├── kafka-consumer/ # Test consumer
│   └── pii-masking/   # PII masking app
├── scripts/           # Setup and utility scripts
└── docs/             # Documentation
```

## 💰 Cost Breakdown (Demo Environment)

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| MSK | 3 brokers (m5.large) | ~$450 |
| EKS | 3 nodes (m5.xlarge) | ~$400 |
| RDS Oracle | db.m5.xlarge | ~$600 |
| Redshift | 2 nodes (dc2.large) | ~$360 |
| NAT Gateways | 3 AZs | ~$135 |
| Data Transfer | Estimated | ~$100 |
| **Total** | | **~$2,045** |

## 🏷️ Resource Tagging

All resources are tagged with:
- `Project: demo_rt_the_one`
- `Environment: demo`
- `ManagedBy: terraform`
- `CostCenter: demo_rt_the_one`

## 🛠️ Common Operations

### View Infrastructure Outputs
```bash
cd terraform/environments/demo
terraform output
```

### Check Debezium Status
```bash
kubectl get kafkaconnectors -n kafka
kubectl logs -n kafka -l strimzi.io/cluster=debezium-connect-cluster
```

### Monitor MSK Topics
```bash
# List topics
aws kafka list-topics --cluster-arn $(terraform output -raw msk_cluster_arn)

# Check consumer lag
kubectl exec -n kafka debezium-connect-cluster-0 -- \
  kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVERS \
  --describe --group debezium-connect-cluster
```

### Access Redshift
```bash
# Get credentials
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw redshift_master_password_secret_arn)

# Connect using psql
psql -h $(terraform output -raw redshift_endpoint | cut -d: -f1) \
  -p 5439 -U admin -d cdcdemo
```

## 📈 Scaling Guide

### 100k records/sec (Demo)
- Current configuration
- 10-20 partitions per topic
- 3 Debezium tasks

### 1M records/sec (Production)
- Upgrade MSK to m5.4xlarge
- 100-200 partitions per topic
- 10 Debezium tasks
- Enable provisioned throughput

### 10M records/sec (Enterprise)
- Switch to MSK Provisioned
- 500-1000 partitions
- Multi-cluster federation
- Custom partition strategy

## 🔒 Security Features

- **Encryption**: At-rest and in-transit
- **IAM Authentication**: For MSK access
- **Private Subnets**: All data plane components
- **PII Masking**: Real-time data anonymization
- **Secrets Management**: AWS Secrets Manager integration

## 🧹 Cleanup

To destroy all resources:
```bash
make destroy
```

## 📚 Additional Documentation

- [Detailed Architecture](docs/architecture.md)
- [Operational Runbook](docs/runbook.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Performance Tuning](docs/performance.md)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Run `make validate` before committing
4. Submit a pull request

## 📞 Support

For issues or questions:
- Check the [troubleshooting guide](docs/troubleshooting.md)
- Review CloudWatch logs
- Contact the platform team

---

Built with ❤️ for real-time data processing