#!/bin/bash
# deploy-demo.sh - Lean deployment script for CDC demo

set -e

# Configuration
PROJECT_NAME="oracle-cdc-pipeline"
ENVIRONMENT="demo"
REGION="ap-southeast-1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# Check prerequisites
check_prerequisites() {
    log_step "Checking Prerequisites"
    
    local required_tools=("terraform" "kubectl" "aws" "jq" "docker")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    log_info "All prerequisites met ✓"
}

# Initialize Terraform backend
init_backend() {
    log_step "Initializing Terraform Backend"
    
    # Create backend resources if they don't exist
    BUCKET_NAME="${PROJECT_NAME}-tfstate-${ENVIRONMENT}"
    TABLE_NAME="${PROJECT_NAME}-tflock-${ENVIRONMENT}"
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
        log_info "Creating S3 bucket for Terraform state..."
        aws s3api create-bucket \
            --bucket $BUCKET_NAME \
            --region $REGION \
            --create-bucket-configuration LocationConstraint=$REGION
        
        aws s3api put-bucket-versioning \
            --bucket $BUCKET_NAME \
            --versioning-configuration Status=Enabled
    fi
    
    # Check if DynamoDB table exists
    if ! aws dynamodb describe-table --table-name $TABLE_NAME --region $REGION 2>/dev/null; then
        log_info "Creating DynamoDB table for state locking..."
        aws dynamodb create-table \
            --table-name $TABLE_NAME \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
            --region $REGION
    fi
    
    log_info "Backend initialized ✓"
}

# Deploy infrastructure
deploy_infrastructure() {
    log_step "Deploying Infrastructure"
    
    cd terraform/environments/demo
    
    # Clean any existing state
    if [ -f "terraform.tfstate" ]; then
        log_warn "Found local state file, backing up..."
        mv terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d-%H%M%S)
    fi
    
    # Initialize Terraform
    terraform init -upgrade \
        -backend-config="bucket=$BUCKET_NAME" \
        -backend-config="key=demo/terraform.tfstate" \
        -backend-config="region=$REGION" \
        -backend-config="dynamodb_table=$TABLE_NAME"
    
    # Create plan
    log_info "Creating deployment plan..."
    terraform plan -out=tfplan \
        -var="environment=$ENVIRONMENT" \
        -var="enable_msk=false" \
        -var="single_az=true"
    
    # Apply with auto-approve for demo
    log_info "Applying infrastructure changes..."
    terraform apply tfplan
    
    # Export outputs
    terraform output -json > outputs.json
    
    cd - > /dev/null
    log_info "Infrastructure deployed ✓"
}

# Deploy Kafka in Kubernetes
deploy_kafka_in_k8s() {
    log_step "Deploying Kafka in Kubernetes"
    
    # Update kubeconfig
    CLUSTER_NAME=$(cd terraform/environments/demo && terraform output -raw eks_cluster_id)
    aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME
    
    # Create namespace
    kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Strimzi operator
    log_info "Installing Strimzi Kafka operator..."
    kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
    
    # Wait for operator
    kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n kafka --timeout=300s
    
    # Deploy single-node Kafka
    log_info "Deploying Kafka cluster..."
    kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: demo-kafka-cluster
  namespace: kafka
spec:
  kafka:
    version: 3.7.0
    replicas: 1
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: true
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
      limits:
        memory: 2Gi
        cpu: 1000m
  zookeeper:
    replicas: 1
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: true
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
      limits:
        memory: 1Gi
        cpu: 500m
  entityOperator:
    topicOperator:
      resources:
        requests:
          memory: 256Mi
          cpu: 100m
    userOperator:
      resources:
        requests:
          memory: 256Mi
          cpu: 100m
EOF
    
    # Wait for Kafka to be ready
    kubectl wait --for=condition=ready kafka/demo-kafka-cluster -n kafka --timeout=600s
    
    log_info "Kafka deployed ✓"
}

# Create Kafka topics
create_kafka_topics() {
    log_step "Creating Kafka Topics"
    
    local topics=("oracle.cdc.customers" "oracle.cdc.products" "oracle.cdc.orders")
    
    for topic in "${topics[@]}"; do
        kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: ${topic//./-}
  namespace: kafka
  labels:
    strimzi.io/cluster: demo-kafka-cluster
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 604800000
    compression.type: lz4
EOF
    done
    
    log_info "Topics created ✓"
}

# Deploy Debezium
deploy_debezium() {
    log_step "Deploying Debezium"
    
    # Get RDS endpoint
    RDS_ENDPOINT=$(cd terraform/environments/demo && terraform output -raw rds_endpoint)
    RDS_HOST=$(echo $RDS_ENDPOINT | cut -d: -f1)
    
    # Create secrets
    kubectl create secret generic oracle-creds \
        --from-literal=username=admin \
        --from-literal=password='DemoPass123!' \
        -n kafka --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy Kafka Connect
    kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: debezium-connect
  namespace: kafka
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  replicas: 1
  bootstrapServers: demo-kafka-cluster-kafka-bootstrap:9092
  config:
    group.id: debezium-connect
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
    config.storage.replication.factor: 1
    offset.storage.replication.factor: 1
    status.storage.replication.factor: 1
  build:
    output:
      type: docker
      image: debezium/connect:2.5
    plugins:
      - name: debezium-oracle
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/2.5.1.Final/debezium-connector-oracle-2.5.1.Final-plugin.tar.gz
  resources:
    requests:
      memory: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1000m
EOF
    
    # Wait for Connect to be ready
    kubectl wait --for=condition=ready kafkaconnect/debezium-connect -n kafka --timeout=600s
    
    # Create Oracle connector
    kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: oracle-cdc-connector
  namespace: kafka
  labels:
    strimzi.io/cluster: debezium-connect
spec:
  class: io.debezium.connector.oracle.OracleConnector
  tasksMax: 1
  config:
    database.hostname: "${RDS_HOST}"
    database.port: 1521
    database.user: cdc_user
    database.password: "CdcDemo2024!"
    database.dbname: ORCLCDB
    database.server.name: oracle
    schema.include.list: CDC_USER
    table.include.list: CDC_USER.CUSTOMERS,CDC_USER.PRODUCTS,CDC_USER.ORDERS
    topic.prefix: oracle.cdc
    snapshot.mode: initial
    log.mining.strategy: online_catalog
EOF
    
    log_info "Debezium deployed ✓"
}

# Deploy PII Masking
deploy_pii_masking() {
    log_step "Deploying PII Masking"
    
    # Deploy PII masking application
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pii-masking
  namespace: kafka
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pii-masking
  template:
    metadata:
      labels:
        app: pii-masking
    spec:
      containers:
      - name: pii-masking
        image: confluentinc/cp-kafka-streams:latest
        env:
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: demo-kafka-cluster-kafka-bootstrap:9092
        - name: APPLICATION_ID
          value: pii-masking-app
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: 500m
EOF
    
    log_info "PII Masking deployed ✓"
}

# Initialize databases
init_databases() {
    log_step "Initializing Databases"
    
    log_info "Please run the following SQL scripts:"
    echo "1. Oracle: scripts/init/01-init-oracle-db.sql"
    echo "2. Redshift: scripts/init/02-init-redshift.sql"
    
    # Display connection info
    echo -e "\n${YELLOW}Oracle Connection:${NC}"
    cd terraform/environments/demo
    echo "Host: $(terraform output -raw rds_endpoint)"
    echo "User: admin"
    echo "Database: ORCLCDB"
    
    echo -e "\n${YELLOW}Redshift Connection:${NC}"
    echo "Host: $(terraform output -raw redshift_endpoint)"
    echo "User: admin"
    echo "Database: cdcdemo"
    cd - > /dev/null
}

# Main deployment function
main() {
    log_info "Starting CDC Demo Deployment"
    
    # Parse arguments
    SKIP_INFRA=false
    SKIP_K8S=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-infra)
                SKIP_INFRA=true
                shift
                ;;
            --skip-k8s)
                SKIP_K8S=true
                shift
                ;;
            --help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --skip-infra    Skip infrastructure deployment"
                echo "  --skip-k8s      Skip Kubernetes deployments"
                exit 0
                ;;
        esac
    done
    
    # Execute deployment steps
    check_prerequisites
    
    if [ "$SKIP_INFRA" != "true" ]; then
        init_backend
        deploy_infrastructure
    fi
    
    if [ "$SKIP_K8S" != "true" ]; then
        deploy_kafka_in_k8s
        create_kafka_topics
        deploy_debezium
        deploy_pii_masking
    fi
    
    init_databases
    
    log_info "Deployment complete! 🎉"
    
    # Print access information
    echo -e "\n${GREEN}=== Access Information ===${NC}"
    echo "Kafka UI: kubectl port-forward -n kafka svc/demo-kafka-cluster-kafka-bootstrap 9092:9092"
    echo "Debezium: kubectl get kafkaconnectors -n kafka"
    echo ""
    echo "Next steps:"
    echo "1. Initialize databases with provided SQL scripts"
    echo "2. Monitor pipeline: ./scripts/monitor-pipeline.sh"
    echo "3. Generate test data: ./scripts/generate-test-data.sh"
}

# Run main function
main "$@"