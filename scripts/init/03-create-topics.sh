#!/bin/bash
# Create Kafka topics

NAMESPACE="kafka"

# Wait for Kafka to be ready
kubectl wait --for=condition=ready kafka/demo-kafka-cluster -n $NAMESPACE --timeout=300s

# Create topics
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: oracle.cdc.customers
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: demo-kafka-cluster
spec:
  partitions: 3
  replicas: 1
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: oracle.cdc.products
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: demo-kafka-cluster
spec:
  partitions: 3
  replicas: 1
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: oracle.cdc.orders
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: demo-kafka-cluster
spec:
  partitions: 3
  replicas: 1
EOF

echo "✅ Topics created!"