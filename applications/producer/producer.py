#!/usr/bin/env python3
"""
Oracle CDC Producer Application
Reads changes from Oracle using polling and publishes to Kafka
"""

import os
import sys
import json
import time
import signal
import logging
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
import cx_Oracle
from kafka import KafkaProducer
from kafka.errors import KafkaError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration from environment
ORACLE_DSN = os.environ.get('ORACLE_ENDPOINT')
ORACLE_USER = os.environ.get('ORACLE_USERNAME', 'admin')
ORACLE_PASSWORD = os.environ.get('ORACLE_PASSWORD')
KAFKA_BOOTSTRAP = os.environ.get('KAFKA_BOOTSTRAP_SERVERS')

class OracleCDCProducer:
    def __init__(self):
        self.running = True
        self.oracle_conn = None
        self.kafka_producer = None
        self.last_scn = None
        self.executor = ThreadPoolExecutor(max_workers=5)
        
    def connect_oracle(self):
        """Connect to Oracle database"""
        try:
            self.oracle_conn = cx_Oracle.connect(
                user=ORACLE_USER,
                password=ORACLE_PASSWORD,
                dsn=ORACLE_DSN,
                encoding="UTF-8"
            )
            logger.info("Connected to Oracle database")
        except Exception as e:
            logger.error(f"Failed to connect to Oracle: {e}")
            raise
            
    def setup_kafka(self):
        """Setup Kafka producer"""
        try:
            self.kafka_producer = KafkaProducer(
                bootstrap_servers=KAFKA_BOOTSTRAP.split(','),
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                acks='all',
                retries=3,
                max_in_flight_requests_per_connection=5
            )
            logger.info("Kafka producer initialized")
        except Exception as e:
            logger.error(f"Failed to setup Kafka: {e}")
            raise
            
    def get_current_scn(self):
        """Get current SCN from Oracle"""
        cursor = self.oracle_conn.cursor()
        cursor.execute("SELECT CURRENT_SCN FROM V$DATABASE")
        scn = cursor.fetchone()[0]
        cursor.close()
        return scn
        
    def poll_changes(self):
        """Poll for changes using Flashback Query"""
        cursor = self.oracle_conn.cursor()
        
        try:
            # If first run, get current SCN
            if self.last_scn is None:
                self.last_scn = self.get_current_scn()
                logger.info(f"Starting from SCN: {self.last_scn}")
                return
                
            current_scn = self.get_current_scn()
            
            # Query for changes using Flashback
            query = """
                SELECT 
                    VERSIONS_STARTSCN,
                    VERSIONS_ENDSCN,
                    VERSIONS_OPERATION,
                    VERSIONS_XID,
                    s.*
                FROM demo_user.S_CONTACT 
                    VERSIONS BETWEEN SCN :last_scn AND :current_scn s
                WHERE VERSIONS_STARTSCN IS NOT NULL
                ORDER BY VERSIONS_STARTSCN
            """
            
            cursor.execute(query, last_scn=self.last_scn, current_scn=current_scn)
            
            changes = []
            for row in cursor:
                change = {
                    'scn': row[0],
                    'operation': row[2],  # I, U, D
                    'transaction_id': row[3],
                    'timestamp': datetime.now().isoformat(),
                    'data': {}
                }
                
                # Get column names
                col_names = [col[0].lower() for col in cursor.description[4:]]
                
                # Build data dictionary
                for i, col_name in enumerate(col_names):
                    value = row[i + 4]
                    if isinstance(value, datetime):
                        value = value.isoformat()
                    elif isinstance(value, cx_Oracle.LOB):
                        value = value.read()
                    change['data'][col_name] = value
                    
                changes.append(change)
                
            # Process changes
            for change in changes:
                self.send_to_kafka(change)
                
            # Update last SCN
            if changes:
                self.last_scn = current_scn
                logger.info(f"Processed {len(changes)} changes, new SCN: {self.last_scn}")
                
        except Exception as e:
            logger.error(f"Error polling changes: {e}")
        finally:
            cursor.close()
            
    def send_to_kafka(self, change):
        """Send change event to Kafka"""
        topic = "cdc.demo_user.s_contact"
        
        # Map Oracle operation to CDC operation
        op_map = {'I': 'c', 'U': 'u', 'D': 'd'}
        
        # Build CDC event
        cdc_event = {
            'schema': 'demo_user',
            'table': 's_contact',
            'op': op_map.get(change['operation'], 'r'),
            'ts_ms': int(time.time() * 1000),
            'transaction': {
                'id': change['transaction_id'],
                'scn': change['scn']
            },
            'source': {
                'db': 'CDCDEMO',
                'schema': 'demo_user',
                'table': 's_contact',
                'scn': change['scn']
            }
        }
        
        # Add data based on operation
        if change['operation'] in ['I', 'U']:
            cdc_event['after'] = change['data']
        if change['operation'] == 'D':
            cdc_event['before'] = change['data']
            
        # Use ROW_ID as key
        key = change['data'].get('row_id', '').encode('utf-8')
        
        try:
            future = self.kafka_producer.send(topic, value=cdc_event, key=key)
            record_metadata = future.get(timeout=10)
            logger.debug(f"Sent to {record_metadata.topic}:{record_metadata.partition}:{record_metadata.offset}")
        except KafkaError as e:
            logger.error(f"Failed to send to Kafka: {e}")
            # Send to DLQ
            self.send_to_dlq(cdc_event, str(e))
            
    def send_to_dlq(self, event, error):
        """Send failed events to DLQ"""
        dlq_topic = "cdc.dlq.s_contact"
        dlq_event = {
            'original_event': event,
            'error': error,
            'error_timestamp': datetime.now().isoformat()
        }
        
        try:
            self.kafka_producer.send(dlq_topic, value=dlq_event)
        except Exception as e:
            logger.error(f"Failed to send to DLQ: {e}")
            
    def run(self):
        """Main run loop"""
        self.connect_oracle()
        self.setup_kafka()
        
        logger.info("Starting CDC producer...")
        
        while self.running:
            try:
                self.poll_changes()
                time.sleep(1)  # Poll every second
            except KeyboardInterrupt:
                logger.info("Received interrupt signal")
                break
            except Exception as e:
                logger.error(f"Error in main loop: {e}")
                time.sleep(5)
                
    def shutdown(self):
        """Graceful shutdown"""
        logger.info("Shutting down...")
        self.running = False
        
        if self.kafka_producer:
            self.kafka_producer.flush()
            self.kafka_producer.close()
            
        if self.oracle_conn:
            self.oracle_conn.close()
            
        self.executor.shutdown(wait=True)
        logger.info("Shutdown complete")

def main():
    # Signal handler
    def signal_handler(sig, frame):
        logger.info(f"Received signal {sig}")
        producer.shutdown()
        sys.exit(0)
        
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Run producer
    producer = OracleCDCProducer()
    
    try:
        producer.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        producer.shutdown()
        sys.exit(1)

if __name__ == "__main__":
    main()