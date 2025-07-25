#!/bin/bash
# scripts/setup/04-install-strimzi.sh

set -e

echo "Installing Strimzi operator..."

# Create kafka namespace
kubectl create namespace kafka || true

# Install Strimzi operator
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Wait for operator to be ready
echo "Waiting for Strimzi operator to be ready..."
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=300s

echo "Strimzi operator installed successfully!"