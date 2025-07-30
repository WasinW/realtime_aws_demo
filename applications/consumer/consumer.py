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
KAFKA_BROKERS = os.environ.get('KAFKA_BROKERS', '').split(',')
S3_BUCKET = os.environ.get('S3_BUCKET')
DLQ_BUCKET = os.environ.get('DLQ_BUCKET')
REDSHIFT_ENDPOINT = os.environ.get('REDSHIFT_ENDPOINT')
REDSHIFT_DATABASE = os.environ.get('REDSHIFT_DATABASE', 'crmanalytics')
REDSHIFT_USERNAME = os.environ.get('REDSHIFT_USERNAME')
REDSHIFT_PASSWORD = os.environ.get('REDSHIFT_PASSWORD')
REDSHIFT_ROLE_ARN = os.environ.get('REDSHIFT_ROLE_ARN')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-1')

# Topics to consume
TOPICS = [
    'cdc.crm.s_contact',
    'cdc.crm.s_org_ext',
    'cdc.crm.s_opty',
    'cdc.crm.s_order',
    'cdc.crm.s_order_item',
    'cdc.crm.s_activity'
]

class CDCConsumer:
    def __init__(self):
        self.running = True
        self.kafka_consumer = None
        self.s3_client = boto3.client('s3', region_name=AWS_REGION)
        self.redshift_conn = None
        self.buffers = {topic: [] for topic in TOPICS}
        self.last_flush = {topic: datetime.now() for topic in TOPICS}
        self.executor = ThreadPoolExecutor(max_workers=10)
        
        # Configuration
        self.buffer_size = 10000
        self.flush_interval_seconds = 60
        
    def setup_kafka(self):
        """Setup Kafka consumer"""
        try:
            self.kafka_consumer = KafkaConsumer(
                *TOPICS,
                bootstrap_servers=KAFKA_BROKERS,
                auto_offset_reset='earliest',
                enable_auto_commit=False,
                group_id='cdc-s3-consumer-group',
                value_deserializer=lambda m: json.loads(m.decode('utf-8')),
                max_poll_records=1000,
                session_timeout_ms=30000,
                heartbeat_interval_ms=10000
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
                user=REDSHIFT_USERNAME,
                password=REDSHIFT_PASSWORD
            )
            self.redshift_conn.autocommit = True
            logger.info("Connected to Redshift")
        except Exception as e:
            logger.error(f"Failed to connect to Redshift: {e}")
            raise
            
    def process_message(self, message):
        """Process a single Kafka message"""
        try:
            topic = message.topic
            value = message.value
            
            # Add Kafka metadata
            value['kafka_timestamp'] = datetime.fromtimestamp(
                message.timestamp / 1000
            ).isoformat()
            value['kafka_offset'] = message.offset
            value['kafka_partition'] = message.partition
            
            # Buffer the message
            self.buffers[topic].append(value)
            
            # Check if we should flush
            if (len(self.buffers[topic]) >= self.buffer_size or
                (datetime.now() - self.last_flush[topic]).seconds >= self.flush_interval_seconds):
                self.flush_buffer(topic)
                
        except Exception as e:
            logger.error(f"Error processing message: {e}")
            # Send to DLQ
            self.send_to_dlq(message, str(e))
            
    def flush_buffer(self, topic):
        """Flush buffer to S3 and load to Redshift"""
        if not self.buffers[topic]:
            return
            
        try:
            # Get table name from topic
            table_name = topic.split('.')[-1]
            
            # Prepare data
            records = self.buffers[topic].copy()
            self.buffers[topic].clear()
            self.last_flush[topic] = datetime.now()
            
            # Add S3 write timestamp
            s3_timestamp = datetime.now().isoformat()
            for record in records:
                record['s3_write_timestamp'] = s3_timestamp
            
            # Convert to Parquet and write to S3
            s3_path = self.write_to_s3(records, table_name)
            
            # Load to Redshift
            self.load_to_redshift(s3_path, table_name)
            
            # Commit Kafka offsets
            self.kafka_consumer.commit()
            
            logger.info(f"Flushed {len(records)} records for {table_name}")
            
        except Exception as e:
            logger.error(f"Error flushing buffer for {topic}: {e}")
            # Put records back in buffer for retry
            self.buffers[topic].extend(records)
            raise
            
    def write_to_s3(self, records, table_name):
        """Write records to S3 as Parquet"""
        # Generate S3 path with date partitioning
        now = datetime.now()
        s3_key = (
            f"cdc/{table_name}/"
            f"year={now.year}/month={now.month:02d}/day={now.day:02d}/"
            f"{table_name}_{now.strftime('%Y%m%d_%H%M%S')}_{int(time.time())}.parquet"
        )
        
        # Convert to PyArrow Table
        # Flatten nested structures
        flattened_records = []
        for record in records:
            flat_record = self.flatten_record(record)
            flattened_records.append(flat_record)
        
        # Create PyArrow table
        table = pa.Table.from_pylist(flattened_records)
        
        # Write to local file first
        local_path = f"/tmp/{os.path.basename(s3_key)}"
        pq.write_table(
            table,
            local_path,
            compression='snappy',
            use_dictionary=True,
            use_deprecated_int96_timestamps=True
        )
        
        # Upload to S3
        self.s3_client.upload_file(
            local_path,
            S3_BUCKET,
            s3_key
        )
        
        # Clean up local file
        os.remove(local_path)
        
        logger.info(f"Wrote {len(records)} records to s3://{S3_BUCKET}/{s3_key}")
        
        return f"s3://{S3_BUCKET}/{s3_key}"
        
    def flatten_record(self, record):
        """Flatten nested CDC record structure"""
        flat = {}
        
        # CDC metadata
        flat['cdc_operation'] = record.get('op', '')
        flat['cdc_timestamp'] = datetime.fromtimestamp(
            record.get('ts_ms', 0) / 1000
        ).isoformat()
        flat['kafka_timestamp'] = record.get('kafka_timestamp')
        flat['s3_write_timestamp'] = record.get('s3_write_timestamp')
        
        # Extract data based on operation
        data = {}
        if record.get('op') in ['c', 'u', 'r']:  # create, update, read
            data = record.get('after', {})
        elif record.get('op') == 'd':  # delete
            data = record.get('before', {})
            
        # Add all data fields
        for key, value in data.items():
            # Convert dates/timestamps
            if isinstance(value, str) and 'T' in value:
                try:
                    # Try to parse as ISO datetime
                    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
                    flat[key.lower()] = dt.isoformat()
                except:
                    flat[key.lower()] = value
            else:
                flat[key.lower()] = value
                
        return flat
        
    def load_to_redshift(self, s3_path, table_name):
        """Load data from S3 to Redshift using COPY command"""
        cursor = self.redshift_conn.cursor()
        
        try:
            # COPY to staging table first
            staging_table = f"crm_cdc.stg_{table_name}"
            target_table = f"crm_cdc.{table_name}"
            
            # Truncate staging table
            cursor.execute(f"TRUNCATE TABLE {staging_table}")
            
            # COPY from S3
            copy_sql = f"""
                COPY {staging_table}
                FROM '{s3_path}'
                IAM_ROLE '{REDSHIFT_ROLE_ARN}'
                FORMAT AS PARQUET
                TIMEFORMAT 'auto'
                TRUNCATECOLUMNS
                BLANKSASNULL
                EMPTYASNULL
            """
            cursor.execute(copy_sql)
            
            # Insert into main table
            insert_sql = f"""
                INSERT INTO {target_table}
                SELECT * FROM {staging_table}
            """
            cursor.execute(insert_sql)
            
            # Get row count
            cursor.execute(f"SELECT COUNT(*) FROM {staging_table}")
            row_count = cursor.fetchone()[0]
            
            logger.info(f"Loaded {row_count} rows to Redshift table {target_table}")
            
        except Exception as e:
            logger.error(f"Error loading to Redshift: {e}")
            raise
        finally:
            cursor.close()
            
    def send_to_dlq(self, message, error_reason):
        """Send failed message to DLQ"""
        try:
            dlq_record = {
                'original_topic': message.topic,
                'original_offset': message.offset,
                'original_partition': message.partition,
                'original_timestamp': message.timestamp,
                'error_reason': error_reason,
                'error_timestamp': datetime.now().isoformat(),
                'original_value': message.value
            }
            
            # Write to DLQ S3 bucket
            now = datetime.now()
            dlq_key = (
                f"dlq/{message.topic}/"
                f"year={now.year}/month={now.month:02d}/day={now.day:02d}/"
                f"error_{now.strftime('%Y%m%d_%H%M%S')}_{message.offset}.json"
            )
            
            self.s3_client.put_object(
                Bucket=DLQ_BUCKET,
                Key=dlq_key,
                Body=json.dumps(dlq_record),
                ContentType='application/json'
            )
            
            logger.warning(f"Sent message to DLQ: {dlq_key}")
            
        except Exception as e:
            logger.error(f"Failed to send to DLQ: {e}")
            
    def run(self):
        """Main consumer loop"""
        self.setup_kafka()
        self.connect_redshift()
        
        logger.info("Starting CDC consumer...")
        
        try:
            while self.running:
                # Poll for messages
                messages = self.kafka_consumer.poll(timeout_ms=1000)
                
                for topic_partition, records in messages.items():
                    for record in records:
                        self.process_message(record)
                        
                # Periodic flush check
                for topic in TOPICS:
                    if (datetime.now() - self.last_flush[topic]).seconds >= self.flush_interval_seconds:
                        self.flush_buffer(topic)
                        
        except KeyboardInterrupt:
            logger.info("Received interrupt signal")
        except Exception as e:
            logger.error(f"Fatal error in consumer: {e}")
        finally:
            self.shutdown()
            
    def shutdown(self):
        """Graceful shutdown"""
        logger.info("Shutting down CDC consumer...")
        self.running = False
        
        # Flush all buffers
        for topic in TOPICS:
            if self.buffers[topic]:
                try:
                    self.flush_buffer(topic)
                except:
                    pass
                    
        # Close connections
        if self.kafka_consumer:
            self.kafka_consumer.close()
            
        if self.redshift_conn:
            self.redshift_conn.close()
            
        # Shutdown executor
        self.executor.shutdown(wait=True)
        
        logger.info("CDC consumer shutdown complete")

def main():
    # Signal handlers
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