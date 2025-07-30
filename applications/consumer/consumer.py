#!/usr/bin/env python3
"""
CDC Consumer Application
Consumes CDC events from Kafka and writes to S3/Redshift
"""

import os
import sys
import json
import time
import signal
import logging
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
import boto3
import psycopg2
from kafka import KafkaConsumer
from kafka.errors import KafkaError
import pyarrow as pa
import pyarrow.parquet as pq

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration from environment
KAFKA_BOOTSTRAP = os.environ.get('KAFKA_BOOTSTRAP_SERVERS')
S3_DATA_BUCKET = os.environ.get('S3_DATA_BUCKET')
S3_DLQ_BUCKET = os.environ.get('S3_DLQ_BUCKET')
REDSHIFT_ENDPOINT = os.environ.get('REDSHIFT_ENDPOINT')
REDSHIFT_DATABASE = os.environ.get('REDSHIFT_DATABASE', 'cdcdemo')
REDSHIFT_USER = os.environ.get('REDSHIFT_USERNAME', 'admin')
REDSHIFT_PASSWORD = os.environ.get('REDSHIFT_PASSWORD')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-1')

class CDCConsumer:
    def __init__(self):
        self.running = True
        self.kafka_consumer = None
        self.s3_client = boto3.client('s3', region_name=AWS_REGION)
        self.redshift_conn = None
        self.buffer = []
        self.buffer_size = 1000
        self.buffer_timeout = 30  # seconds
        self.last_flush = time.time()
        self.executor = ThreadPoolExecutor(max_workers=5)
        
    def setup_kafka(self):
        """Setup Kafka consumer"""
        try:
            self.kafka_consumer = KafkaConsumer(
                'cdc.demo_user.s_contact',
                bootstrap_servers=KAFKA_BOOTSTRAP.split(','),
                auto_offset_reset='earliest',
                enable_auto_commit=False,
                group_id='cdc-consumer-group',
                value_deserializer=lambda m: json.loads(m.decode('utf-8'))
            )
            logger.info("Kafka consumer initialized")
        except Exception as e:
            logger.error(f"Failed to setup Kafka consumer: {e}")
            raise
            
    def connect_redshift(self):
        """Connect to Redshift"""
        try:
            self.redshift_conn = psycopg2.connect(
                host=REDSHIFT_ENDPOINT,
                port=5439,
                database=REDSHIFT_DATABASE,
                user=REDSHIFT_USER,
                password=REDSHIFT_PASSWORD
            )
            self.redshift_conn.autocommit = True
            logger.info("Connected to Redshift")
        except Exception as e:
            logger.error(f"Failed to connect to Redshift: {e}")
            raise
            
    def process_message(self, message):
        """Process a single message"""
        try:
            cdc_event = message.value
            
            # Add Kafka metadata
            cdc_event['kafka_timestamp'] = datetime.fromtimestamp(
                message.timestamp / 1000
            ).isoformat()
            cdc_event['kafka_offset'] = message.offset
            cdc_event['kafka_partition'] = message.partition
            
            # Add to buffer
            self.buffer.append(cdc_event)
            
            # Check if we should flush
            if len(self.buffer) >= self.buffer_size or \
               (time.time() - self.last_flush) > self.buffer_timeout:
                self.flush_buffer()
                
        except Exception as e:
            logger.error(f"Error processing message: {e}")
            self.send_to_dlq(message, str(e))
            
    def flush_buffer(self):
        """Flush buffer to S3 and Redshift"""
        if not self.buffer:
            return
            
        try:
            # Generate S3 key with timestamp
            timestamp = datetime.now()
            s3_key = f"cdc/s_contact/year={timestamp.year}/month={timestamp.month:02d}/day={timestamp.day:02d}/{timestamp.strftime('%Y%m%d_%H%M%S')}.parquet"
            
            # Convert to Parquet
            records = []
            for event in self.buffer:
                record = {}
                
                # Get data from event
                data = event.get('after', event.get('before', {}))
                if data:
                    record.update(data)
                    
                # Add CDC metadata
                record['_cdc_operation'] = event.get('op', 'r')
                record['_cdc_timestamp'] = event.get('ts_ms', 0)
                record['_kafka_timestamp'] = event.get('kafka_timestamp')
                record['_s3_write_timestamp'] = datetime.now().isoformat()
                
                records.append(record)
                
            # Create Parquet table
            df = pa.Table.from_pylist(records)
            
            # Write to S3
            s3_path = f"s3://{S3_DATA_BUCKET}/{s3_key}"
            pq.write_table(df, s3_path)
            
            logger.info(f"Wrote {len(records)} records to {s3_path}")
            
            # Load to Redshift
            self.load_to_redshift(s3_path)
            
            # Clear buffer and commit offsets
            self.buffer.clear()
            self.kafka_consumer.commit()
            self.last_flush = time.time()
            
        except Exception as e:
            logger.error(f"Error flushing buffer: {e}")
            # Don't clear buffer so we can retry
            
    def load_to_redshift(self, s3_path):
        """Load data from S3 to Redshift"""
        cursor = self.redshift_conn.cursor()
        
        try:
            # Create IAM role for Redshift if not exists
            iam_role = f"arn:aws:iam::{boto3.client('sts').get_caller_identity()['Account']}:role/oracle-cdc-demo-redshift-role"
            
            # Truncate staging table
            cursor.execute("TRUNCATE TABLE cdc.s_contact_staging")
            
            # COPY from S3 to staging
            copy_query = f"""
                COPY cdc.s_contact_staging
                FROM '{s3_path}'
                IAM_ROLE '{iam_role}'
                FORMAT AS PARQUET
                TIMEFORMAT 'YYYY-MM-DD HH:MI:SS'
                TRUNCATECOLUMNS
            """
            cursor.execute(copy_query)
            
            # Merge into main table
            merge_query = """
                INSERT INTO cdc.s_contact
                SELECT * FROM cdc.s_contact_staging
            """
            cursor.execute(merge_query)
            
            logger.info("Data loaded to Redshift successfully")
            
        except Exception as e:
            logger.error(f"Error loading to Redshift: {e}")
            raise
        finally:
            cursor.close()
            
    def send_to_dlq(self, message, error):
        """Send failed messages to DLQ"""
        try:
            dlq_record = {
                'original_message': message.value,
                'error': error,
                'error_timestamp': datetime.now().isoformat(),
                'topic': message.topic,
                'partition': message.partition,
                'offset': message.offset
            }
            
            # Write to S3 DLQ bucket
            timestamp = datetime.now()
            s3_key = f"dlq/s_contact/{timestamp.strftime('%Y/%m/%d')}/{message.offset}.json"
            
            self.s3_client.put_object(
                Bucket=S3_DLQ_BUCKET,
                Key=s3_key,
                Body=json.dumps(dlq_record),
                ContentType='application/json'
            )
            
            logger.warning(f"Sent message to DLQ: {s3_key}")
            
        except Exception as e:
            logger.error(f"Failed to send to DLQ: {e}")
            
    def run(self):
        """Main run loop"""
        self.setup_kafka()
        self.connect_redshift()
        
        logger.info("Starting CDC consumer...")
        
        try:
            for message in self.kafka_consumer:
                if not self.running:
                    break
                    
                self.process_message(message)
                
        except KeyboardInterrupt:
            logger.info("Received interrupt signal")
        except Exception as e:
            logger.error(f"Error in consumer loop: {e}")
            
    def shutdown(self):
        """Graceful shutdown"""
        logger.info("Shutting down...")
        self.running = False
        
        # Flush remaining buffer
        if self.buffer:
            self.flush_buffer()
            
        # Close connections
        if self.kafka_consumer:
            self.kafka_consumer.close()
            
        if self.redshift_conn:
            self.redshift_conn.close()
            
        self.executor.shutdown(wait=True)
        logger.info("Shutdown complete")

def main():
    # Signal handler
    def signal_handler(sig, frame):
        logger.info(f"Received signal {sig}")
        consumer.shutdown()
        sys.exit(0)
        
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Run consumer
    consumer = CDCConsumer()
    
    try:
        consumer.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        consumer.shutdown()
        sys.exit(1)

if __name__ == "__main__":
    main()