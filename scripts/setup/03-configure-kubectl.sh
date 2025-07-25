#!/bin/bash
# scripts/setup/03-configure-kubectl.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"

echo "Configuring kubectl..."

# Get cluster name from Terraform output
cd ${PROJECT_ROOT}/terraform/environments/demo
CLUSTER_NAME=$(terraform output -raw eks_cluster_id)
REGION=$(terraform output -raw region)

# Update kubeconfig
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}

# Verify connection
kubectl cluster-info

echo "kubectl configured successfully!"
