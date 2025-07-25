#!/bin/bash
# scripts/setup/02-deploy-infrastructure.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"

echo "Deploying infrastructure with Terraform..."

cd ${PROJECT_ROOT}/terraform/environments/demo

# Initialize Terraform
terraform init

# Create plan
terraform plan -out=tfplan

# Apply plan
terraform apply tfplan

# Save outputs
terraform output -json > outputs.json

echo "Infrastructure deployment complete!"
echo "Run 'terraform output' to see the outputs"
