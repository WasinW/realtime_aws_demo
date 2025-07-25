# CDC Pipeline Troubleshooting Guide

## Common Issues and Solutions

### 1. Debezium Connector Issues

#### Connector Not Starting
**Symptoms:**
- Connector status shows as FAILED
- No CDC events being produced

**Diagnosis:**
```bash
# Check connector status
kubectl get kafkaconnectors -n kafka

# View connector logs
kubectl logs -n kafka -l strimzi.io/cluster=debezium-connect-cluster

# Check specific connector status
kubectl describe kafkaconnector oracle-cdc-connector -n kafka
```

**Common Causes & Solutions:**

1. **Oracle supplemental logging not enabled**
   ```sql
   -- Connect to Oracle as SYSDBA
   ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
   ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
   
   -- Verify
   SELECT supplemental_log_data_min FROM v$database;
   ```

2. **Insufficient Oracle privileges**
   ```sql
   -- Grant missing privileges
   GRANT SELECT ANY TABLE TO debezium;
   GRANT LOGMINING TO debezium;
   GRANT SELECT ON V_$LOGMNR_CONTENTS TO debezium;
   ```

3. **Network connectivity issues**
   ```bash
   # Test connectivity from pod
   kubectl exec -it debezium-connect-cluster-0 -n kafka -- nc -zv oracle-host 1521
   ```

#### High Memory Usage
**Symptoms:**
- Connector pods getting OOMKilled
- Slow CDC processing

**Solution:**
```yaml
# Increase memory in KafkaConnect resource
resources:
  limits:
    memory: 6Gi
  requests:
    memory: 4Gi

jvmOptions:
  -Xms: 2048m
  -Xmx: 4096m
```

### 2. MSK Issues

#### Cannot Connect to MSK
**Symptoms:**
- Connection refused errors
- Authentication failures

**Diagnosis:**
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxx

# Verify IAM role
kubectl describe sa debezium-connect -n kafka

# Test connectivity
kubectl run test-pod --image=busybox -it --rm -- sh
# Inside pod:
telnet broker-1.kafka.region.amazonaws.com 9098
```

**Solutions:**

1. **Security group missing ports**
   - Add ingress rules for ports 9092, 9094, 9098

2. **IAM role not properly configured**
   ```bash
   # Update service account annotation
   kubectl annotate serviceaccount debezium-connect \
     eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/msk-access-role \
     -n kafka --overwrite
   ```

#### High Consumer Lag
**Symptoms:**
- Increasing lag in consumer groups
- Slow data processing

**Diagnosis:**
```bash
# Check consumer lag
kubectl exec -n kafka debezium-connect-cluster-0 -- \
  kafka-consumer-groups.sh \
  --bootstrap-server $BOOTSTRAP_SERVERS \
  --describe --group pii-masking-app
```

**Solutions:**

1. **Scale consumers**
   ```bash
   kubectl scale deployment pii-masking -n kafka --replicas=5
   ```

2. **Increase partitions**
   ```bash
   # Create topic with more partitions
   kafka-topics.sh --alter \
     --topic oracle.inventory.customers \
     --partitions 20 \
     --bootstrap-server $BOOTSTRAP_SERVERS
   ```

### 3. PII Masking Application Issues

#### Application Crashes
**Symptoms:**
- Pods in CrashLoopBackOff
- Kafka Streams errors

**Diagnosis:**
```bash
# Check pod logs
kubectl logs -n kafka pii-masking-xxxx-xxxx

# Describe pod
kubectl describe pod pii-masking-xxxx-xxxx -n kafka
```

**Common Causes:**

1. **State store corruption**
   ```bash
   # Delete and restart pods to rebuild state
   kubectl delete pods -n kafka -l app=pii-masking
   ```

2. **Memory issues**
   ```yaml
   # Increase JVM heap
   env:
   - name: JAVA_OPTS
     value: "-Xmx4g -Xms2g"
   ```

### 4. Redshift Issues

#### Materialized Views Not Refreshing
**Symptoms:**
- Stale data in Redshift
- Materialized view refresh errors

**Diagnosis:**
```sql
-- Check materialized view status
SELECT * FROM STV_MV_INFO WHERE name LIKE 'customers_stream';

-- Check for errors
SELECT * FROM STL_LOAD_ERRORS ORDER BY starttime DESC LIMIT 10;
```

**Solutions:**

1. **IAM role permissions**
   ```bash
   # Verify Redshift can access MSK
   aws iam simulate-principal-policy \
     --policy-source-arn arn:aws:iam::123456789012:role/redshift-msk-role \
     --action-names kafka:DescribeCluster kafka-cluster:ReadData
   ```

2. **Manual refresh**
   ```sql
   REFRESH MATERIALIZED VIEW staging.customers_stream;
   ```

### 5. Performance Issues

#### Slow CDC Processing
**Symptoms:**
- High latency between Oracle changes and Redshift
- Low throughput

**Optimization Steps:**

1. **Tune Debezium**
   ```yaml
   config:
     max.batch.size: 5000
     poll.interval.ms: 500
     log.mining.batch.size.default: 50000
   ```

2. **Optimize Kafka**
   ```properties
   # Producer settings
   batch.size=1000000
   linger.ms=200
   compression.type=lz4
   
   # Consumer settings
   fetch.min.bytes=500000
   max.poll.records=5000
   ```

3. **Scale infrastructure**
   ```bash
   # Scale EKS nodes
   eksctl scale nodegroup --cluster=debezium-cdc-cluster \
     --nodes=5 --name=debezium-nodes
   ```

### 6. Data Quality Issues

#### Missing or Duplicate Records
**Symptoms:**
- Row count mismatches
- Duplicate events in Redshift

**Diagnosis:**
```python
# Run data quality checker
python scripts/monitoring/check-data-quality.py \
  --redshift-host redshift-cluster.region.redshift.amazonaws.com \
  --redshift-password $REDSHIFT_PASSWORD
```

**Solutions:**

1. **Enable exactly-once semantics**
   ```yaml
   config:
     processing.guarantee: exactly_once_v2
     enable.idempotence: true
   ```

2. **Add deduplication in Redshift**
   ```sql
   -- Create deduplicated view
   CREATE VIEW marts.customers_dedup AS
   SELECT DISTINCT ON (customer_id) *
   FROM marts.dim_customers
   ORDER BY customer_id, valid_from DESC;
   ```

## Monitoring Commands Reference

### Kafka/MSK
```bash
# List topics
kafka-topics.sh --list --bootstrap-server $BOOTSTRAP_SERVERS

# Describe topic
kafka-topics.sh --describe --topic oracle.inventory.customers \
  --bootstrap-server $BOOTSTRAP_SERVERS

# Consumer group status
kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVERS \
  --group debezium-connect-cluster --describe

# Reset consumer offset
kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP_SERVERS \
  --group pii-masking-app --reset-offsets --to-earliest \
  --topic oracle.inventory.customers --execute
```

### Kubernetes
```bash
# Get all resources
kubectl get all -n kafka

# View pod logs
kubectl logs -f -n kafka deployment/pii-masking

# Execute commands in pod
kubectl exec -it -n kafka debezium-connect-cluster-0 -- bash

# Port forward for debugging
kubectl port-forward -n kafka svc/debezium-connect-cluster-connect-api 8083:8083
```

### AWS CLI
```bash
# MSK cluster status
aws kafka describe-cluster --cluster-arn $MSK_CLUSTER_ARN

# List MSK topics
aws kafka list-topics --cluster-arn $MSK_CLUSTER_ARN

# Redshift cluster status
aws redshift describe-clusters --cluster-identifier oracle-cdc-pipeline-demo-redshift
```

## Emergency Procedures

### Complete Pipeline Restart
```bash
# 1. Stop consumers
kubectl scale deployment pii-masking -n kafka --replicas=0

# 2. Stop Debezium
kubectl delete kafkaconnector oracle-cdc-connector -n kafka

# 3. Clear topics (if needed)
kafka-topics.sh --delete --topic oracle.inventory.* \
  --bootstrap-server $BOOTSTRAP_SERVERS

# 4. Restart in order
kubectl apply -f kubernetes/debezium/04-oracle-connector.yaml
kubectl scale deployment pii-masking -n kafka --replicas=3
```

### Rollback Procedure
```bash
# 1. Capture current state
kubectl get all -n kafka -o yaml > backup-$(date +%Y%m%d).yaml

# 2. Apply previous configuration
kubectl apply -f backup-20240115.yaml

# 3. Verify rollback
kubectl get pods -n kafka -w
```

## Support Contacts

- **Platform Team**: platform@company.com
- **On-Call**: Use PagerDuty
- **Slack Channel**: #cdc-pipeline-support

## Additional Resources

- [Debezium Documentation](https://debezium.io/documentation/)
- [MSK Best Practices](https://docs.aws.amazon.com/msk/latest/developerguide/best-practices.html)
- [Kafka Streams Troubleshooting](https://kafka.apache.org/documentation/streams/)
- [Redshift Streaming Ingestion Guide](https://docs.aws.amazon.com/redshift/latest/dg/materialized-view-streaming-ingestion.html)