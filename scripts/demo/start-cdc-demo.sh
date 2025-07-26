#!/bin/bash
# Start CDC demo

# 1. Start Kafka Connect
echo "1. Starting Kafka Connect..."
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: debezium-connect
  namespace: kafka
spec:
  replicas: 1
  bootstrapServers: demo-kafka-cluster-kafka-bootstrap:9092
  config:
    group.id: debezium-connect
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
  build:
    output:
      type: docker
      image: debezium/connect:2.5
    plugins:
      - name: debezium-oracle
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/2.5.1.Final/debezium-connector-oracle-2.5.1.Final-plugin.tar.gz
EOF

# 2. Create Debezium connector
echo "2. Creating Oracle CDC connector..."
kubectl wait --for=condition=ready kafkaconnect/debezium-connect -n kafka --timeout=300s

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
    database.user: debezium
    database.password: "${DEBEZIUM_PASSWORD}"
    database.dbname: ORCLCDB
    database.server.name: oracle
    schema.include.list: CDC_USER
    table.include.list: CDC_USER.CUSTOMERS,CDC_USER.PRODUCTS,CDC_USER.ORDERS
    topic.prefix: oracle.cdc
    snapshot.mode: initial
EOF

# 3. Monitor logs
echo "3. Monitoring CDC pipeline..."
echo "Connector logs:"
kubectl logs -f deployment/debezium-connect-connect -n kafka