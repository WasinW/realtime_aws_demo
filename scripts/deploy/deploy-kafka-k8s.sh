#!/bin/bash
# Deploy and manage Kafka on Kubernetes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        print_error "helm not found. Please install helm."
        exit 1
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    print_status "All prerequisites met!"
}

# Deploy infrastructure
deploy_infrastructure() {
    print_status "Deploying infrastructure with Terraform..."
    
    cd terraform/demo
    terraform init
    terraform apply -auto-approve
    
    # Get outputs
    export EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
    export ORACLE_ENDPOINT=$(terraform output -raw oracle_endpoint)
    export S3_BUCKET=$(terraform output -raw s3_data_bucket)
    export DLQ_BUCKET=$(terraform output -raw s3_dlq_bucket)
    export REDSHIFT_ENDPOINT=$(terraform output -raw redshift_endpoint)
    export REDSHIFT_ROLE_ARN=$(terraform output -raw redshift_role_arn)
    
    cd ../..
}

# Configure kubectl
configure_kubectl() {
    print_status "Configuring kubectl..."
    aws eks update-kubeconfig --region ${AWS_REGION:-ap-southeast-1} --name ${EKS_CLUSTER_NAME}
    
    # Verify connection
    kubectl cluster-info
}

# Wait for Kafka to be ready
wait_for_kafka() {
    print_status "Waiting for Kafka cluster to be ready..."
    
    # Wait for Kafka pods
    kubectl wait --for=condition=ready pod -l strimzi.io/cluster=cdc-cluster,strimzi.io/kind=Kafka -n kafka --timeout=600s
    
    # Wait for Kafka bootstrap service
    kubectl wait --for=condition=ready pod -l strimzi.io/name=cdc-cluster-kafka -n kafka --timeout=300s
    
    print_status "Kafka cluster is ready!"
}

# Create Kafka topics
create_kafka_topics() {
    print_status "Creating Kafka topics..."
    
    # Create a job to create topics
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: create-topics
  namespace: kafka
spec:
  template:
    spec:
      containers:
      - name: kafka-client
        image: quay.io/strimzi/kafka:0.38.0-kafka-3.5.1
        command:
        - /bin/bash
        - -c
        - |
          # Wait for Kafka to be ready
          sleep 30
          
          # Create topics
          for topic in s_contact s_org_ext s_opty s_order s_order_item s_activity; do
            echo "Creating topic: cdc.crm.\${topic}"
            bin/kafka-topics.sh --create \
              --bootstrap-server cdc-cluster-kafka-bootstrap:9092 \
              --topic cdc.crm.\${topic} \
              --partitions 10 \
              --replication-factor 3 \
              --config retention.ms=604800000 \
              --config compression.type=lz4
          done
          
          # Create DLQ topics
          for topic in s_contact s_org_ext s_opty s_order s_order_item s_activity general; do
            echo "Creating DLQ topic: cdc.dlq.\${topic}"
            bin/kafka-topics.sh --create \
              --bootstrap-server cdc-cluster-kafka-bootstrap:9092 \
              --topic cdc.dlq.\${topic} \
              --partitions 5 \
              --replication-factor 3
          done
          
          # List all topics
          echo "All topics:"
          bin/kafka-topics.sh --list --bootstrap-server cdc-cluster-kafka-bootstrap:9092
      restartPolicy: Never
EOF
    
    # Wait for job completion
    kubectl wait --for=condition=complete job/create-topics -n kafka --timeout=300s
    
    # Show logs
    kubectl logs job/create-topics -n kafka
}

# Get Kafka external endpoint
get_kafka_endpoint() {
    print_status "Getting Kafka external endpoint..."
    
    # Get LoadBalancer service endpoint
    KAFKA_EXTERNAL_ENDPOINT=$(kubectl get service cdc-cluster-kafka-external-bootstrap -n kafka -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$KAFKA_EXTERNAL_ENDPOINT" ]; then
        KAFKA_EXTERNAL_ENDPOINT=$(kubectl get service cdc-cluster-kafka-external-bootstrap -n kafka -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    if [ -z "$KAFKA_EXTERNAL_ENDPOINT" ]; then
        print_warning "External endpoint not ready yet. Using internal endpoint."
        KAFKA_ENDPOINT="cdc-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
    else
        KAFKA_ENDPOINT="${KAFKA_EXTERNAL_ENDPOINT}:9094"
    fi
    
    print_status "Kafka endpoint: ${KAFKA_ENDPOINT}"
}

# Get Kafka UI endpoint
get_kafka_ui_endpoint() {
    print_status "Getting Kafka UI endpoint..."
    
    KAFKA_UI_ENDPOINT=$(kubectl get service kafka-ui -n kafka -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$KAFKA_UI_ENDPOINT" ]; then
        KAFKA_UI_ENDPOINT=$(kubectl get service kafka-ui -n kafka -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    fi
    
    print_status "Kafka UI available at: http://${KAFKA_UI_ENDPOINT}"
}

# Main deployment
main() {
    print_status "Starting Kafka on Kubernetes deployment..."
    
    check_prerequisites
    deploy_infrastructure
    configure_kubectl
    wait_for_kafka
    create_kafka_topics
    get_kafka_endpoint
    get_kafka_ui_endpoint
    
    print_status "Deployment complete!"
    print_status ""
    print_status "Next steps:"
    print_status "1. Initialize Oracle database: ./scripts/init/01-create-oracle-objects.sql"
    print_status "2. Deploy CDC applications: kubectl apply -f kubernetes/"
    print_status "3. Generate test data: python3 scripts/mock-data/generate_crm_data.py"
    print_status ""
    print_status "Kafka UI: http://${KAFKA_UI_ENDPOINT}"
    print_status "Kafka endpoint: ${KAFKA_ENDPOINT}"
}

# Run main function
main