#!/bin/bash
# Build and push Docker images to ECR

set -e

# Configuration
AWS_REGION=${AWS_REGION:-ap-southeast-1}
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/oracle-cdc-demo"

# Create ECR repository if not exists
create_ecr_repo() {
    echo "Creating ECR repository..."
    aws ecr describe-repositories --repository-names oracle-cdc-demo --region ${AWS_REGION} || \
    aws ecr create-repository --repository-name oracle-cdc-demo --region ${AWS_REGION}
}

# Login to ECR
login_ecr() {
    echo "Logging in to ECR..."
    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REPO}
}

# Build and push producer
build_producer() {
    echo "Building producer image..."
    cd applications/producer
    docker build -t cdc-producer:latest .
    docker tag cdc-producer:latest ${ECR_REPO}/cdc-producer:latest
    docker push ${ECR_REPO}/cdc-producer:latest
    cd ../..
}

# Build and push consumer
build_consumer() {
    echo "Building consumer image..."
    cd applications/consumer
    docker build -t cdc-consumer:latest .
    docker tag cdc-consumer:latest ${ECR_REPO}/cdc-consumer:latest
    docker push ${ECR_REPO}/cdc-consumer:latest
    cd ../..
}

# Main
main() {
    create_ecr_repo
    login_ecr
    build_producer
    build_consumer
    
    echo "Images pushed successfully!"
    echo "Producer: ${ECR_REPO}/cdc-producer:latest"
    echo "Consumer: ${ECR_REPO}/cdc-consumer:latest"
}

main