#!/bin/bash
# deploy.sh - One-click deployment script for CDC Pipeline

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="oracle-cdc-pipeline"
AWS_REGION=${AWS_REGION:-"ap-southeast-1"}  # เปลี่ยนจาก ap-southeast-1
ENVIRONMENT="demo"

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required tools
    local required_tools=("terraform" "kubectl" "aws" "jq" "python3")
    for tool in "${required_tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool is not installed"
            exit 1
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    log_info "All prerequisites met ✓"
}

setup_terraform_backend() {
    log_info "Setting up Terraform backend..."
    bash scripts/setup/01-init-terraform-backend.sh
}

deploy_infrastructure() {
    log_info "Deploying infrastructure with Terraform..."
    
    cd terraform/environments/demo
    
    # Initialize Terraform
    terraform init
    
    # Create plan with auto-approve for demo
    if [ "$1" == "--auto-approve" ]; then
        terraform apply -auto-approve
    else
        terraform plan -out=tfplan
        
        echo -e "\n${YELLOW}Please review the plan above.${NC}"
        read -p "Do you want to apply this plan? (yes/no): " confirm
        
        if [[ $confirm == "yes" ]]; then
            terraform apply tfplan
        else
            log_warn "Deployment cancelled"
            exit 0
        fi
    fi
    
    # Save outputs
    terraform output -json > outputs.json
    
    cd ../../..
}

configure_kubernetes() {
    log_info "Configuring Kubernetes..."
    
    # Get EKS cluster name
    CLUSTER_NAME=$(cd terraform/environments/demo && terraform output -raw eks_cluster_id)
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
    
    # Verify connection
    kubectl cluster-info
}

install_operators() {
    log_info "Installing Kubernetes operators..."
    
    # Create namespace
    kubectl create namespace kafka || true
    
    # Install Strimzi
    kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
    
    # Wait for operator
    kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=300s
}

create_secrets() {
    log_info "Creating secrets..."
    
    cd terraform/environments/demo
    
    # Get RDS credentials
    RDS_SECRET_ARN=$(terraform output -raw rds_master_password_secret_arn)
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    
    # Get secret value
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id $RDS_SECRET_ARN --query SecretString --output text)
    DB_USERNAME=$(echo $SECRET_JSON | jq -r .username)
    DB_PASSWORD=$(echo $SECRET_JSON | jq -r .password)
    
    # Create secrets
    kubectl create secret generic oracle-credentials \
        --from-literal=username=$DB_USERNAME \
        --from-literal=password=$DB_PASSWORD \
        --from-literal=endpoint=$RDS_ENDPOINT \
        -n kafka || true
    
    kubectl create secret generic debezium-credentials \
        --from-literal=username=debezium \
        --from-literal=password='D3b3z1um#2024' \
        -n kafka || true
    
    cd ../../..
}

deploy_applications() {
    log_info "Deploying applications..."
    
    cd terraform/environments/demo
    
    # Get necessary values
    MSK_BOOTSTRAP_SERVERS=$(terraform output -raw msk_bootstrap_brokers_iam)
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    RDS_HOST=$(echo $RDS_ENDPOINT | cut -d: -f1)
    MSK_CLUSTER_ARN=$(terraform output -raw msk_cluster_arn)
    MSK_ACCESS_ROLE_ARN=$(terraform output -raw msk_access_role_arn)
    ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com
    
    cd ../../..
    
    # Build and push PII masking application
    log_info "Building PII masking application..."
    cd applications/pii-masking
    
    # Build JAR
    if command -v mvn &> /dev/null; then
        mvn clean package
    else
        log_warn "Maven not installed, skipping Java build"
    fi
    
    # Build and push Docker image
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
    
    # Create ECR repository if it doesn't exist
    aws ecr create-repository --repository-name pii-masking --region $AWS_REGION || true
    
    docker build -t pii-masking .
    docker tag pii-masking:latest $ECR_REGISTRY/pii-masking:latest
    docker push $ECR_REGISTRY/pii-masking:latest
    
    cd ../..
    
    # Deploy Debezium
    log_info "Deploying Debezium connector..."
    
    # Create ECR repository for Debezium
    aws ecr create-repository --repository-name debezium-connect-oracle --region $AWS_REGION || true
    
    # Apply Kubernetes manifests with substituted values
    for file in kubernetes/debezium/*.yaml; do
        sed -e "s|\${MSK_BOOTSTRAP_SERVERS}|$MSK_BOOTSTRAP_SERVERS|g" \
            -e "s|\${RDS_ENDPOINT}|$RDS_HOST|g" \
            -e "s|\${MSK_ACCESS_ROLE_ARN}|$MSK_ACCESS_ROLE_ARN|g" \
            -e "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" \
            -e "s|\${DEBEZIUM_PASSWORD}|D3b3z1um#2024|g" \
            $file | kubectl apply -f -
    done
    
    # Deploy PII masking application
    log_info "Deploying PII masking application..."
    
    for file in kubernetes/kafka-streams/*.yaml; do
        sed -e "s|\${MSK_BOOTSTRAP_SERVERS}|$MSK_BOOTSTRAP_SERVERS|g" \
            -e "s|\${MSK_ACCESS_ROLE_ARN}|$MSK_ACCESS_ROLE_ARN|g" \
            -e "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" \
            -e "s|\${AWS_REGION}|$AWS_REGION|g" \
            $file | kubectl apply -f -
    done
}

setup_monitoring() {
    log_info "Setting up monitoring..."
    
    # Create monitoring namespace
    kubectl create namespace monitoring || true
    
    # Install Prometheus operator (simplified for demo)
    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/bundle.yaml
    
    # Apply monitoring configurations
    kubectl apply -f kubernetes/monitoring/
}

run_tests() {
    log_info "Running integration tests..."
    
    cd terraform/environments/demo
    MSK_CLUSTER_ARN=$(terraform output -raw msk_cluster_arn)
    cd ../../..
    
    # Install Python dependencies
    pip install -r applications/kafka-producer/requirements.txt
    pip install -r applications/kafka-consumer/requirements.txt
    
    # Run producer for 30 seconds
    log_info "Starting test data producer..."
    python applications/kafka-producer/producer.py \
        --cluster-arn $MSK_CLUSTER_ARN \
        --duration 30 \
        --rate 10 &
    
    PRODUCER_PID=$!
    
    # Run consumer
    log_info "Starting test consumer..."
    python applications/kafka-consumer/consumer.py \
        --cluster-arn $MSK_CLUSTER_ARN \
        --topics oracle.inventory.customers oracle.inventory.products oracle.inventory.orders &
    
    CONSUMER_PID=$!
    
    # Wait for producer to finish
    wait $PRODUCER_PID
    
    # Let consumer process for 10 more seconds
    sleep 10
    
    # Stop consumer
    kill $CONSUMER_PID 2>/dev/null || true
    
    log_info "Integration tests completed"
}

print_summary() {
    log_info "Deployment completed successfully! 🎉"
    
    echo -e "\n${GREEN}=== Deployment Summary ===${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Region: $AWS_REGION"
    echo "Project: $PROJECT_NAME"
    
    cd terraform/environments/demo
    
    echo -e "\n${GREEN}=== Access Information ===${NC}"
    echo "MSK Cluster ARN: $(terraform output -raw msk_cluster_arn)"
    echo "EKS Cluster: $(terraform output -raw eks_cluster_id)"
    echo "Redshift Endpoint: $(terraform output -raw redshift_endpoint)"
    
    echo -e "\n${GREEN}=== Next Steps ===${NC}"
    echo "1. Monitor the pipeline:"
    echo "   python scripts/monitoring/monitor-pipeline.py --msk-cluster-arn \$(terraform output -raw msk_cluster_arn) --redshift-cluster oracle-cdc-pipeline-demo-redshift"
    echo ""
    echo "2. Check data quality:"
    echo "   python scripts/monitoring/check-data-quality.py --redshift-host \$(terraform output -raw redshift_endpoint | cut -d: -f1) --redshift-password <password>"
    echo ""
    echo "3. View Kubernetes resources:"
    echo "   kubectl get all -n kafka"
    echo ""
    echo "4. Access Debezium UI:"
    echo "   kubectl port-forward -n kafka svc/debezium-connect-cluster-connect-api 8083:8083"
    echo "   Open http://localhost:8083"
    
    echo -e "\n${GREEN}=== Cost Information ===${NC}"
    echo "Estimated monthly cost: ~\$2,045"
    echo "Remember to destroy resources when done: make destroy"
    
    cd ../../..
}

# Main execution
main() {
    echo -e "${GREEN}=== CDC Pipeline Deployment Script ===${NC}\n"
    
    check_prerequisites
    
    # Parse arguments
    AUTO_APPROVE=""
    SKIP_TESTS=false
    
    for arg in "$@"; do
        case $arg in
            --auto-approve)
                AUTO_APPROVE="--auto-approve"
                ;;
            --skip-tests)
                SKIP_TESTS=true
                ;;
            --help)
                echo "Usage: $0 [--auto-approve] [--skip-tests]"
                echo "  --auto-approve: Skip confirmation prompts"
                echo "  --skip-tests: Skip integration tests"
                exit 0
                ;;
        esac
    done
    
    # Execute deployment steps
    setup_terraform_backend
    deploy_infrastructure $AUTO_APPROVE
    configure_kubernetes
    install_operators
    create_secrets
    deploy_applications
    setup_monitoring
    
    if [ "$SKIP_TESTS" = false ]; then
        run_tests
    fi
    
    print_summary
}

# Run main function
main "$@"