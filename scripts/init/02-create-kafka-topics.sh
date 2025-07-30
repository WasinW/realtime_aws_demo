#!/bin/bash
# Create Kafka topics for CDC

# Configuration
KAFKA_BOOTSTRAP_SERVERS="$1"
REPLICATION_FACTOR=3
PARTITIONS=10

# Check if bootstrap servers provided
if [ -z "$KAFKA_BOOTSTRAP_SERVERS" ]; then
    echo "Usage: $0 <kafka-bootstrap-servers>"
    exit 1
fi

# Install Kafka client tools if not present
if ! command -v kafka-topics.sh &> /dev/null; then
    cd /tmp
    wget https://downloads.apache.org/kafka/3.5.1/kafka_2.13-3.5.1.tgz
    tar -xzf kafka_2.13-3.5.1.tgz
    export PATH=$PATH:/tmp/kafka_2.13-3.5.1/bin
fi

# Function to create topic
create_topic() {
    local topic_name=$1
    local partitions=${2:-$PARTITIONS}
    
    echo "Creating topic: $topic_name with $partitions partitions"
    
    kafka-topics.sh \
        --bootstrap-server $KAFKA_BOOTSTRAP_SERVERS \
        --create \
        --topic $topic_name \
        --partitions $partitions \
        --replication-factor $REPLICATION_FACTOR \
        --config retention.ms=604800000 \
        --config compression.type=lz4 \
        --config max.message.bytes=10485760 \
        --if-not-exists
}

# Create CDC topics for each CRM table
create_topic "cdc.crm.s_contact" 20
create_topic "cdc.crm.s_org_ext" 20
create_topic "cdc.crm.s_opty" 20
create_topic "cdc.crm.s_order" 30
create_topic "cdc.crm.s_order_item" 30
create_topic "cdc.crm.s_activity" 20

# Create DLQ topics
create_topic "cdc.dlq.s_contact" 5
create_topic "cdc.dlq.s_org_ext" 5
create_topic "cdc.dlq.s_opty" 5
create_topic "cdc.dlq.s_order" 5
create_topic "cdc.dlq.s_order_item" 5
create_topic "cdc.dlq.s_activity" 5

# Create a general DLQ topic
create_topic "cdc.dlq.general" 10

# List all topics
echo "Listing all topics:"
kafka-topics.sh \
    --bootstrap-server $KAFKA_BOOTSTRAP_SERVERS \
    --list