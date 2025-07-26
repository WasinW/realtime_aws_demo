#!/bin/bash
# Monitor CDC pipeline

# Watch topics
watch -n 2 "kubectl exec -n kafka demo-kafka-cluster-kafka-0 -- \
  bin/kafka-topics.sh --list --bootstrap-server localhost:9092 | \
  xargs -I {} sh -c 'echo Topic: {} && \
  kubectl exec -n kafka demo-kafka-cluster-kafka-0 -- \
  bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 --topic {} --time -1 | \
  awk -F: \"{ sum += \\\$3 } END { print \\\"Messages: \\\" sum }\" && echo'"