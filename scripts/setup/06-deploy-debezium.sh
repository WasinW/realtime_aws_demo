#!/bin/bash
# scripts/setup/06-deploy-debezium.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"

echo "Deploying Debezium connector..."

cd ${PROJECT_ROOT}/terraform/environments/demo

# Get MSK details
MSK_BOOTSTRAP_SERVERS=$(terraform output -raw msk_bootstrap_brokers_iam)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
RDS_HOST=$(echo ${RDS_ENDPOINT} | cut -d: -f1)

# Create Kafka Connect cluster
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: debezium-connect-cluster
  namespace: kafka
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 3.7.0
  replicas: 3
  bootstrapServers: ${MSK_BOOTSTRAP_SERVERS}
  config:
    group.id: debezium-connect-cluster
    offset.storage.topic: connect-cluster-offsets
    config.storage.topic: connect-cluster-configs
    status.storage.topic: connect-cluster-status
    config.storage.replication.factor: 3
    offset.storage.replication.factor: 3
    status.storage.replication.factor: 3
  authentication:
    type: aws-iam
  build:
    output:
      type: docker
      image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/debezium-connect-oracle:latest
    plugins:
      - name: debezium-oracle-connector
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/2.5.1.Final/debezium-connector-oracle-2.5.1.Final-plugin.tar.gz
  resources:
    requests:
      memory: 2Gi
      cpu: 1000m
    limits:
      memory: 4Gi
      cpu: 2000m
EOF

# Wait for Kafka Connect to be ready
kubectl wait --for=condition=ready kafkaconnect/debezium-connect-cluster -n kafka --timeout=600s

# Create Oracle connector
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: oracle-cdc-connector
  namespace: kafka
  labels:
    strimzi.io/cluster: debezium-connect-cluster
spec:
  class: io.debezium.connector.oracle.OracleConnector
  tasksMax: 1
  config:
    database.hostname: ${RDS_HOST}
    database.port: 1521
    database.user: debezium
    database.password: D3b3z1um#2024
    database.dbname: ORCLCDB
    database.server.name: oracle-server
    database.connection.adapter: logminer
    log.mining.strategy: online_catalog
    table.include.list: DEMO_USER.CUSTOMERS,DEMO_USER.PRODUCTS,DEMO_USER.ORDERS,DEMO_USER.ORDER_ITEMS
    decimal.handling.mode: string
    include.schema.changes: false
    tombstones.on.delete: false
    max.batch.size: 2048
    max.queue.size: 8192
    poll.interval.ms: 1000
EOF

echo "Debezium deployment complete!"

