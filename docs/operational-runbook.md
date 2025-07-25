# CDC Pipeline Operational Runbook

## Daily Operations

### Morning Health Check (9:00 AM)

1. **Check Pipeline Dashboard**
   ```bash
   python scripts/monitoring/monitor-pipeline.py \
     --msk-cluster-arn $(terraform output -raw msk_cluster_arn) \
     --redshift-cluster oracle-cdc-pipeline-demo-redshift
   ```

2. **Verify Data Freshness**
   ```sql
   -- Connect to Redshift
   SELECT 
     'customers' as table_name,
     MAX(kafka_timestamp) as latest_update,
     CURRENT_TIMESTAMP - MAX(kafka_timestamp) as lag
   FROM staging.customers_stream
   UNION ALL
   SELECT 
     'products',
     MAX(kafka_timestamp),
     CURRENT_TIMESTAMP - MAX(kafka_timestamp)
   FROM staging.products_stream
   UNION ALL
   SELECT 
     'orders',
     MAX(kafka_timestamp),
     CURRENT_TIMESTAMP - MAX(kafka_timestamp)
   FROM staging.orders_stream;
   ```

3. **Check Consumer Lag**
   ```bash
   kubectl exec -n kafka debezium-connect-cluster-0 -- \
     kafka-consumer-groups.sh \
     --bootstrap-server $BOOTSTRAP_SERVERS \
     --describe --all-groups | grep LAG
   ```

4. **Review Overnight Alerts**
   - Check CloudWatch alarms
   - Review PagerDuty incidents
   - Check Slack alerts channel

### Weekly Maintenance

#### Monday: Performance Review
```bash
# Generate performance report
cat > weekly-performance.sql << EOF
-- Weekly throughput analysis
WITH daily_stats AS (
  SELECT 
    DATE_TRUNC('day', kafka_timestamp) as day,
    COUNT(*) as events_processed,
    AVG(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - kafka_timestamp))) as avg_lag_seconds
  FROM staging.customers_stream
  WHERE kafka_timestamp > CURRENT_DATE - INTERVAL '7 days'
  GROUP BY 1
)
SELECT * FROM daily_stats ORDER BY day;
EOF

psql -h $(terraform output -raw redshift_endpoint | cut -d: -f1) \
  -U admin -d cdcdemo -f weekly-performance.sql
```

#### Wednesday: Capacity Planning
```bash
# Check disk usage
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kafka \
  --metric-name KafkaDataLogsDiskUsed \
  --dimensions Name=ClusterName,Value=oracle-cdc-pipeline-demo-msk \
  --statistics Average \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400

# Check topic growth
kubectl exec -n kafka debezium-connect-cluster-0 -- \
  kafka-log-dirs.sh --describe \
  --bootstrap-server $BOOTSTRAP_SERVERS \
  --topic-list oracle.inventory.customers,oracle.inventory.products,oracle.inventory.orders
```

#### Friday: Backup Verification
```bash
# Verify Kafka topic backups
aws s3 ls s3://demo-rt-the-one-backups/kafka-topics/ --recursive \
  | grep $(date +%Y%m%d)

# Test restore procedure (in dev environment)
./scripts/backup/test-restore.sh --date $(date +%Y%m%d)
```

### Monthly Tasks

#### First Monday: Security Review
```bash
# Rotate service account tokens
kubectl delete secret -n kafka debezium-credentials
kubectl create secret generic debezium-credentials \
  --from-literal=username=debezium \
  --from-literal=password='NewPassword#2024' \
  -n kafka

# Review IAM policies
aws iam get-role-policy --role-name oracle-cdc-pipeline-demo-msk-access-role \
  --policy-name msk-access-policy

# Check for unused resources
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=demo_rt_the_one \
  --query 'ResourceTagMappingList[?Tags[?Key==`LastUsed`].Value|[0] < `2024-01-01`]'
```

#### Mid-month: Disaster Recovery Test
```bash
# 1. Document current state
./scripts/dr/capture-state.sh > dr-test-$(date +%Y%m%d).json

# 2. Simulate failure (in DR region)
./scripts/dr/failover-test.sh --dry-run

# 3. Verify data consistency
python scripts/monitoring/check-data-quality.py \
  --compare-regions ap-southeast-1 us-west-2
```

## Incident Response Procedures

### Severity Levels

- **SEV1**: Complete pipeline failure, no data flowing
- **SEV2**: Partial failure, degraded performance
- **SEV3**: Minor issues, monitoring alerts
- **SEV4**: Informational, no immediate action

### SEV1: Complete Pipeline Failure

**Initial Response (0-15 minutes)**
1. **Acknowledge incident** in PagerDuty
2. **Join incident bridge**: #incident-response
3. **Run diagnostics**:
   ```bash
   # Quick health check
   ./scripts/incident/quick-diagnostic.sh
   
   # Capture state
   kubectl get all -n kafka -o wide > incident-$(date +%Y%m%d-%H%M%S).log
   aws kafka describe-cluster --cluster-arn $MSK_CLUSTER_ARN >> incident-*.log
   ```

**Mitigation (15-30 minutes)**
1. **Identify root cause**:
   - MSK cluster down → Check AWS Health Dashboard
   - Debezium crashed → Check pod logs
   - Network issues → Verify security groups/NACLs
   
2. **Apply quick fixes**:
   ```bash
   # Restart failed components
   kubectl rollout restart deployment/pii-masking -n kafka
   kubectl delete pod -n kafka -l strimzi.io/cluster=debezium-connect-cluster
   ```

3. **Verify data flow**:
   ```bash
   # Check if events are flowing
   kubectl exec -n kafka debezium-connect-cluster-0 -- \
     kafka-console-consumer \
     --bootstrap-server $BOOTSTRAP_SERVERS \
     --topic oracle.inventory.customers \
     --max-messages 10
   ```

### SEV2: Performance Degradation

**Symptoms**:
- Consumer lag > 100k messages
- Processing latency > 5 minutes
- CPU/Memory > 80%

**Response**:
1. **Scale resources**:
   ```bash
   # Scale Kafka Streams app
   kubectl scale deployment pii-masking -n kafka --replicas=5
   
   # Scale EKS nodes if needed
   eksctl scale nodegroup --cluster=debezium-cdc-cluster \
     --nodes=5 --name=debezium-nodes
   ```

2. **Optimize configuration**:
   ```bash
   # Increase batch sizes
   kubectl set env deployment/pii-masking -n kafka \
     KAFKA_BATCH_SIZE=1000000 \
     KAFKA_LINGER_MS=200
   ```

3. **Add monitoring**:
   ```bash
   # Enable detailed metrics
   kubectl annotate deployment pii-masking -n kafka \
     prometheus.io/scrape=true \
     prometheus.io/port=8080
   ```

## Maintenance Procedures

### Planned Maintenance Window

**Pre-maintenance (T-24 hours)**
1. Send notification to stakeholders
2. Prepare rollback plan
3. Test changes in dev environment

**Maintenance Steps**
```bash
# 1. Enable maintenance mode
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: maintenance-mode
  namespace: kafka
data:
  enabled: "true"
  message: "Scheduled maintenance in progress"
EOF

# 2. Stop data producers (gracefully)
kubectl scale deployment pii-masking -n kafka --replicas=0
kubectl patch kafkaconnector oracle-cdc-connector -n kafka \
  --type merge -p '{"spec":{"pause":true}}'

# 3. Wait for pipeline to drain
while [ $(kubectl exec -n kafka debezium-connect-cluster-0 -- \
  kafka-consumer-groups.sh --describe --group pii-masking-app \
  --bootstrap-server $BOOTSTRAP_SERVERS | grep LAG | awk '{sum+=$5} END {print sum}') -gt 0 ]; do
  echo "Waiting for pipeline to drain..."
  sleep 10
done

# 4. Perform maintenance
# ... your maintenance tasks ...

# 5. Resume pipeline
kubectl patch kafkaconnector oracle-cdc-connector -n kafka \
  --type merge -p '{"spec":{"pause":false}}'
kubectl scale deployment pii-masking -n kafka --replicas=3

# 6. Verify data flow
./scripts/verification/post-maintenance-check.sh
```

### Version Upgrades

#### Kafka/MSK Upgrade
```bash
# 1. Check compatibility
aws kafka list-kafka-versions --query 'KafkaVersions[?contains(SupportedClientVersions, `3.5.1`)]'

# 2. Update MSK configuration
terraform plan -var="msk_kafka_version=3.6.0" -out=upgrade.tfplan
terraform apply upgrade.tfplan

# 3. Rolling restart of clients
kubectl rollout restart deployment/pii-masking -n kafka
kubectl delete pods -n kafka -l strimzi.io/cluster=debezium-connect-cluster
```

#### Debezium Upgrade
```bash
# 1. Update connector version
kubectl edit kafkaconnect debezium-connect-cluster -n kafka
# Change plugin URL to new version

# 2. Trigger rebuild
kubectl annotate kafkaconnect debezium-connect-cluster -n kafka \
  strimzi.io/force-rebuild=true

# 3. Monitor rebuild
kubectl logs -n kafka -l strimzi.io/name=debezium-connect-cluster-connect-build -f
```

## Backup and Recovery

### Daily Backup Schedule
```yaml
# kubernetes/backup/cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-backup
  namespace: kafka
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: confluentinc/cp-kafka:latest
            command:
            - /bin/bash
            - -c
            - |
              # Backup topic metadata
              kafka-topics.sh --describe \
                --bootstrap-server $BOOTSTRAP_SERVERS > /backup/topics-$(date +%Y%m%d).txt
              
              # Backup consumer offsets
              kafka-consumer-groups.sh --describe --all-groups \
                --bootstrap-server $BOOTSTRAP_SERVERS > /backup/offsets-$(date +%Y%m%d).txt
              
              # Upload to S3
              aws s3 sync /backup s3://demo-rt-the-one-backups/kafka/
```

### Recovery Procedures

#### Topic Recovery
```bash
# 1. List available backups
aws s3 ls s3://demo-rt-the-one-backups/kafka/

# 2. Download backup
aws s3 cp s3://demo-rt-the-one-backups/kafka/topics-20240120.txt .

# 3. Recreate topics
while IFS= read -r line; do
  if [[ $line == Topic:* ]]; then
    topic=$(echo $line | awk '{print $2}')
    partitions=$(echo $line | grep -oP 'PartitionCount:\K\d+')
    replication=$(echo $line | grep -oP 'ReplicationFactor:\K\d+')
    
    kafka-topics.sh --create \
      --topic $topic \
      --partitions $partitions \
      --replication-factor $replication \
      --bootstrap-server $BOOTSTRAP_SERVERS
  fi
done < topics-20240120.txt
```

## Performance Tuning Guide

### Baseline Metrics
- **Throughput**: 100k records/second
- **Latency**: < 1 second end-to-end
- **Consumer Lag**: < 10k messages
- **CPU Usage**: < 70%
- **Memory Usage**: < 80%

### Optimization Checklist

1. **Kafka Producer Tuning**
   ```properties
   batch.size=1000000           # 1MB batches
   linger.ms=100                # Wait up to 100ms
   compression.type=lz4         # Fast compression
   buffer.memory=134217728      # 128MB buffer
   ```

2. **Consumer Tuning**
   ```properties
   fetch.min.bytes=500000       # 500KB minimum
   max.poll.records=5000        # Process 5k at once
   max.partition.fetch.bytes=10485760  # 10MB per partition
   ```

3. **JVM Tuning**
   ```bash
   export KAFKA_HEAP_OPTS="-Xmx4g -Xms4g"
   export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:+ParallelRefProcEnabled"
   ```

## Monitoring Alerts Configuration

### CloudWatch Alarms
```bash
# High CPU Usage
aws cloudwatch put-metric-alarm \
  --alarm-name "MSK-HighCPU" \
  --alarm-description "MSK CPU usage above 80%" \
  --metric-name CpuUser \
  --namespace AWS/Kafka \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2

# Consumer Lag
aws cloudwatch put-metric-alarm \
  --alarm-name "CDC-HighConsumerLag" \
  --alarm-description "Consumer lag above 100k messages" \
  --metric-name ConsumerLag \
  --namespace CustomMetrics/CDC \
  --statistic Maximum \
  --period 300 \
  --threshold 100000 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

## Contact Information

### Escalation Path
1. **L1 Support**: ops-team@company.com (24/7)
2. **L2 Support**: platform-team@company.com (Business hours)
3. **L3 Support**: architecture-team@company.com (On-call)

### Key Contacts
- **Product Owner**: jane.doe@company.com
- **Tech Lead**: john.smith@company.com
- **AWS TAM**: tam@aws.com

### Communication Channels
- **Slack**: #cdc-pipeline-ops (general), #cdc-pipeline-alerts (automated)
- **Email DL**: cdc-pipeline-team@company.com
- **Confluence**: https://company.atlassian.net/wiki/spaces/CDC
- **Runbook**: https://company.atlassian.net/wiki/spaces/CDC/runbook