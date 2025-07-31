#!/bin/bash
# scripts/init-terraform.sh

set -e

echo "Initializing Terraform for Oracle CDC Demo..."

# Check if terraform.tfvars exists
if [ ! -f "terraform/demo/terraform.tfvars" ]; then
    echo "Creating terraform.tfvars from example..."
    cp terraform/demo/terraform.tfvars.example terraform/demo/terraform.tfvars
    echo "Please edit terraform/demo/terraform.tfvars with your values"
    exit 1
fi

# Generate SSH key if not exists
if [ ! -f "oracle-cdc-demo-key" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f oracle-cdc-demo-key -N ""
fi

# Initialize Terraform
cd terraform/demo
terraform init -upgrade

# Format code
terraform fmt -recursive

echo "Terraform initialization complete!"
echo ""
echo "Next steps:"
echo "1. Edit terraform/demo/terraform.tfvars with your values"
echo "2. Run: terraform plan"
echo "3. Run: terraform apply"