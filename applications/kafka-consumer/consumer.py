# applications/kafka-consumer/consumer.py
import json
import logging
import argparse
import signal
import sys
from typing import Dict, List, Optional
from datetime import datetime
from kafka import KafkaConsumer
from kafka.errors import KafkaError
import boto3

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class CDCConsumer:
    def __init__(self, bootstrap_servers: str, topics: List[str], 
                 group_id: str = "cdc-consumer-group"):
        """Initialize Kafka consumer with MSK IAM authentication"""
        self.topics = topics
        self.group_id = group_id
        self.running = True
        
        self.consumer = KafkaConsumer(
            *topics,
            bootstrap_servers=bootstrap_servers,
            group_id=group_id,
            value_deserializer=lambda m: json.loads(m.decode('utf-8')),
            key_deserializer=lambda k: k.decode('utf-8') if k else None,
            security_protocol='SASL_SSL',
            sasl_mechanism='AWS_MSK_IAM',
            sasl_plain_username='aws',
            sasl_plain_password='aws',
            api_version=(2, 5, 0),
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            auto_commit_interval_ms=5000,
            max_poll_records=500,
            max_poll_interval_ms=300000
        )
        
        # Statistics
        self.stats = {
            'total_messages': 0,
            'inserts': 0,
            'updates': 0,
            'deletes': 0,
            'snapshots': 0,
            'errors': 0,
            'by_table': {}
        }
        
        # Set up signal handlers
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _signal_handler(self, sig, frame):
        """Handle shutdown signals gracefully"""
        logger.info("Shutdown signal received, stopping consumer...")
        self.running = False
    
    def parse_cdc_message(self, message: Dict) -> Optional[Dict]:
        """Parse CDC message and extract relevant information"""
        try:
            payload = message.get('payload', {})
            
            return {
                'operation': payload.get('op'),
                'before': payload.get('before'),
                'after': payload.get('after'),
                'source': payload.get('source', {}),
                'timestamp': payload.get('ts_ms'),
                'table': payload.get('source', {}).get('table'),
                'schema': payload.get('source', {}).get('schema')
            }
        except Exception as e:
            logger.error(f"Error parsing CDC message: {e}")
            return None
    
    def process_message(self, topic: str, message: Dict):
        """Process a single CDC message"""
        parsed = self.parse_cdc_message(message)
        if not parsed:
            self.stats['errors'] += 1
            return
        
        operation = parsed['operation']
        table = parsed['table']
        
        # Update statistics
        self.stats['total_messages'] += 1
        
        if table not in self.stats['by_table']:
            self.stats['by_table'][table] = {
                'inserts': 0, 'updates': 0, 'deletes': 0, 'snapshots': 0
            }
        
        # Process based on operation type
        if operation == 'c':  # Create/Insert
            self.stats['inserts'] += 1
            self.stats['by_table'][table]['inserts'] += 1
            self.handle_insert(parsed)
            
        elif operation == 'u':  # Update
            self.stats['updates'] += 1
            self.stats['by_table'][table]['updates'] += 1
            self.handle_update(parsed)
            
        elif operation == 'd':  # Delete
            self.stats['deletes'] += 1
            self.stats['by_table'][table]['deletes'] += 1
            self.handle_delete(parsed)
            
        elif operation == 'r':  # Read (snapshot)
            self.stats['snapshots'] += 1
            self.stats['by_table'][table]['snapshots'] += 1
            self.handle_snapshot(parsed)
    
    def handle_insert(self, data: Dict):
        """Handle INSERT operation"""
        table = data['table']
        record = data['after']
        
        logger.debug(f"INSERT on {table}: {json.dumps(record, indent=2)}")
        
        # Here you would typically:
        # 1. Apply any business logic
        # 2. Transform the data if needed
        # 3. Write to target system (e.g., Redshift, S3, etc.)
        
    def handle_update(self, data: Dict):
        """Handle UPDATE operation"""
        table = data['table']
        before = data['before']
        after = data['after']
        
        logger.debug(f"UPDATE on {table}")
        logger.debug(f"  Before: {json.dumps(before, indent=2)}")
        logger.debug(f"  After: {json.dumps(after, indent=2)}")
        
        # Identify changed fields
        if before and after:
            changed_fields = {k: {'old': before.get(k), 'new': v} 
                            for k, v in after.items() 
                            if before.get(k) != v}
            logger.debug(f"  Changed fields: {changed_fields}")
    
    def handle_delete(self, data: Dict):
        """Handle DELETE operation"""
        table = data['table']
        record = data['before']
        
        logger.debug(f"DELETE on {table}: {json.dumps(record, indent=2)}")
    
    def handle_snapshot(self, data: Dict):
        """Handle snapshot read"""
        table = data['table']
        record = data['after']
        
        logger.debug(f"SNAPSHOT on {table}: {json.dumps(record, indent=2)}")
    
    def print_statistics(self):
        """Print consumer statistics"""
        logger.info("=" * 60)
        logger.info("Consumer Statistics:")
        logger.info(f"  Total messages: {self.stats['total_messages']}")
        logger.info(f"  Inserts: {self.stats['inserts']}")
        logger.info(f"  Updates: {self.stats['updates']}")
        logger.info(f"  Deletes: {self.stats['deletes']}")
        logger.info(f"  Snapshots: {self.stats['snapshots']}")
        logger.info(f"  Errors: {self.stats['errors']}")
        
        logger.info("\nBy Table:")
        for table, table_stats in self.stats['by_table'].items():
            logger.info(f"  {table}:")
            for op, count in table_stats.items():
                if count > 0:
                    logger.info(f"    {op}: {count}")
        logger.info("=" * 60)
    
    def consume_messages(self):
        """Main consumer loop"""
        logger.info(f"Starting consumer for topics: {self.topics}")
        logger.info(f"Consumer group: {self.group_id}")
        
        message_count = 0
        last_stats_time = datetime.now()
        
        try:
            while self.running:
                # Poll for messages
                messages = self.consumer.poll(timeout_ms=1000)
                
                for topic_partition, records in messages.items():
                    topic = topic_partition.topic
                    
                    for record in records:
                        try:
                            self.process_message(topic, record.value)
                            message_count += 1
                            
                            # Log progress every 100 messages
                            if message_count % 100 == 0:
                                logger.info(f"Processed {message_count} messages...")
                            
                        except Exception as e:
                            logger.error(f"Error processing message: {e}")
                            self.stats['errors'] += 1
                
                # Print statistics every minute
                if (datetime.now() - last_stats_time).seconds >= 60:
                    self.print_statistics()
                    last_stats_time = datetime.now()
                    
        except KeyboardInterrupt:
            logger.info("Consumer interrupted by user")
        except Exception as e:
            logger.error(f"Consumer error: {e}")
        finally:
            self.cleanup()
    
    def cleanup(self):
        """Clean up resources"""
        logger.info("Closing consumer...")
        self.consumer.close()
        self.print_statistics()
        logger.info("Consumer closed successfully")


class CDCValidator(CDCConsumer):
    """Extended consumer for data validation"""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.validation_errors = []
    
    def validate_customer(self, record: Dict) -> List[str]:
        """Validate customer record"""
        errors = []
        
        # Required fields
        required = ['customer_id', 'first_name', 'last_name', 'email']
        for field in required:
            if field not in record or record[field] is None:
                errors.append(f"Missing required field: {field}")
        
        # Email format
        if 'email' in record and record['email']:
            if '@' not in record['email']:
                errors.append(f"Invalid email format: {record['email']}")
        
        # SSN should be masked
        if 'ssn' in record and record['ssn']:
            if not record['ssn'].startswith('XXX-XX-'):
                errors.append("SSN not properly masked")
        
        return errors
    
    def handle_insert(self, data: Dict):
        """Validate INSERT operations"""
        super().handle_insert(data)
        
        table = data['table']
        record = data['after']
        
        if table == 'CUSTOMERS':
            errors = self.validate_customer(record)
            if errors:
                self.validation_errors.append({
                    'table': table,
                    'operation': 'INSERT',
                    'errors': errors,
                    'record': record
                })
                logger.warning(f"Validation errors in {table}: {errors}")


def get_msk_bootstrap_servers(cluster_arn: str) -> str:
    """Get MSK bootstrap servers from cluster ARN"""
    client = boto3.client('kafka')
    
    response = client.get_bootstrap_brokers(ClusterArn=cluster_arn)
    return response['BootstrapBrokerStringSaslIam']


def main():
    parser = argparse.ArgumentParser(description='CDC Event Consumer for MSK')
    parser.add_argument('--cluster-arn', required=True, help='MSK Cluster ARN')
    parser.add_argument('--topics', nargs='+', required=True, help='Topics to consume')
    parser.add_argument('--group-id', default='cdc-consumer-group', help='Consumer group ID')
    parser.add_argument('--validate', action='store_true', help='Enable data validation')
    
    args = parser.parse_args()
    
    # Get bootstrap servers
    bootstrap_servers = get_msk_bootstrap_servers(args.cluster_arn)
    logger.info(f"Bootstrap servers: {bootstrap_servers}")
    
    # Create and run consumer
    if args.validate:
        consumer = CDCValidator(bootstrap_servers, args.topics, args.group_id)
    else:
        consumer = CDCConsumer(bootstrap_servers, args.topics, args.group_id)
    
    consumer.consume_messages()


if __name__ == "__main__":
    main()