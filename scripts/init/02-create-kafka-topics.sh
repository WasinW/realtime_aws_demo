#!/bin/bash
# Create Kafka topics for CDC

KAFKA_BOOTSTRAP="cdc-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"

# Function to create topic
create_topic() {
    local topic=$1
    local partitions=${2:-10}
    
    kubectl exec -n kafka cdc-cluster-kafka-0 -- \
        /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server $KAFKA_BOOTSTRAP \
        --create \
        --topic $topic \
        --partitions $partitions \
        --replication-factor 3 \
        --config retention.ms=604800000 \
        --config compression.type=lz4
}

# Create main CDC topic
create_topic "cdc.demo_user.s_contact" 10

# Create DLQ topic
create_topic "cdc.dlq.s_contact" 3

# List topics
kubectl exec -n kafka cdc-cluster-kafka-0 -- \
    /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server $KAFKA_BOOTSTRAP \
    --list