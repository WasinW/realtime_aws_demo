#!/usr/bin/env python3
"""
Oracle CDC Producer Application
Reads changes from Oracle using LogMiner and publishes to Kafka
"""

import os
import sys
import json
import time
import signal
import logging
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
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
ORACLE_USER = os.environ.get('ORACLE_USERNAME')
ORACLE_PASSWORD = os.environ.get('ORACLE_PASSWORD')
KAFKA_BROKERS = os.environ.get('KAFKA_BROKERS', '').split(',')

# Tables to monitor
TABLES_TO_MONITOR = [
    'S_CONTACT',
    'S_ORG_EXT', 
    'S_OPTY',
    'S_ORDER',
    'S_ORDER_ITEM',
    'S_ACTIVITY'
]

class OracleCDCProducer:
    def __init__(self):
        self.running = True
        self.oracle_conn = None
        self.kafka_producer = None
        self.checkpoints = {}  # Table -> SCN mapping
        self.executor = ThreadPoolExecutor(max_workers=len(TABLES_TO_MONITOR))
        
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
            
            # Enable DBMS_OUTPUT for debugging
            cursor = self.oracle_conn.cursor()
            cursor.callproc("DBMS_OUTPUT.ENABLE")
            cursor.close()
            
        except Exception as e:
            logger.error(f"Failed to connect to Oracle: {e}")
            raise
            
    def setup_kafka(self):
        """Setup Kafka producer"""
        try:
            self.kafka_producer = KafkaProducer(
                bootstrap_servers=KAFKA_BROKERS,
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                key_serializer=lambda k: k.encode('utf-8') if k else None,
                acks='all',
                retries=3,
                max_in_flight_requests_per_connection=5,
                compression_type='lz4',
                batch_size=16384,
                linger_ms=100
            )
            logger.info("Kafka producer initialized")
        except Exception as e:
            logger.error(f"Failed to setup Kafka: {e}")
            raise
            
    def setup_logminer(self):
        """Setup Oracle LogMiner"""
        cursor = self.oracle_conn.cursor()
        
        try:
            # Get current SCN
            cursor.execute("SELECT CURRENT_SCN FROM V$DATABASE")
            current_scn = cursor.fetchone()[0]
            
            # Add redo log files
            cursor.execute("""
                BEGIN
                    FOR log_rec IN (
                        SELECT member FROM v$logfile WHERE type = 'ONLINE'
                    ) LOOP
                        BEGIN
                            DBMS_LOGMNR.ADD_LOGFILE(
                                logfilename => log_rec.member,
                                options => DBMS_LOGMNR.NEW
                            );
                            EXIT;
                        EXCEPTION
                            WHEN OTHERS THEN
                                NULL;
                        END;
                    END LOOP;
                    
                    FOR log_rec IN (
                        SELECT member FROM v$logfile WHERE type = 'ONLINE'
                    ) LOOP
                        BEGIN
                            DBMS_LOGMNR.ADD_LOGFILE(
                                logfilename => log_rec.member,
                                options => DBMS_LOGMNR.ADDFILE
                            );
                        EXCEPTION
                            WHEN OTHERS THEN
                                NULL;
                        END;
                    END LOOP;
                END;
            """)
            
            # Start LogMiner
            start_scn = current_scn - 10000  # Start from 10000 SCNs back
            cursor.execute(f"""
                BEGIN
                    DBMS_LOGMNR.START_LOGMNR(
                        startScn => {start_scn},
                        endScn => {current_scn},
                        OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG +
                                  DBMS_LOGMNR.CONTINUOUS_MINE +
                                  DBMS_LOGMNR.COMMITTED_DATA_ONLY +
                                  DBMS_LOGMNR.SKIP_CORRUPTION
                    );
                END;
            """)
            
            self.oracle_conn.commit()
            logger.info(f"LogMiner started from SCN {start_scn} to {current_scn}")
            
            # Initialize checkpoints
            for table in TABLES_TO_MONITOR:
                self.checkpoints[table] = start_scn
                
        except Exception as e:
            logger.error(f"Failed to setup LogMiner: {e}")
            raise
        finally:
            cursor.close()
            
    def process_table_changes(self, table_name):
        """Process CDC changes for a specific table"""
        cursor = self.oracle_conn.cursor()
        schema = 'CRM_USER'
        
        try:
            while self.running:
                # Query LogMiner for changes
                query = """
                    SELECT 
                        SCN,
                        TIMESTAMP,
                        OPERATION,
                        SQL_REDO,
                        ROW_ID,
                        SEG_OWNER,
                        TABLE_NAME
                    FROM V$LOGMNR_CONTENTS
                    WHERE SEG_OWNER = :owner
                        AND TABLE_NAME = :table_name
                        AND SCN > :last_scn
                        AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
                    ORDER BY SCN
                    FETCH FIRST 1000 ROWS ONLY
                """
                
                cursor.execute(query, {
                    'owner': schema,
                    'table_name': table_name,
                    'last_scn': self.checkpoints[table_name]
                })
                
                changes = cursor.fetchall()
                
                if changes:
                    logger.info(f"Found {len(changes)} changes for {table_name}")
                    
                    for change in changes:
                        scn, timestamp, operation, sql_redo, row_id, seg_owner, table = change
                        
                        # Parse the change
                        cdc_event = {
                            'schema': schema,
                            'table': table_name,
                            'op': self._map_operation(operation),
                            'ts_ms': int(timestamp.timestamp() * 1000),
                            'scn': scn,
                            'row_id': row_id,
                            'source': {
                                'db': 'CRMDB',
                                'schema': schema,
                                'table': table_name,
                                'scn': scn,
                                'timestamp': timestamp.isoformat()
                            }
                        }
                        
                        # Extract data from SQL_REDO
                        data = self._parse_sql_redo(sql_redo, operation)
                        if data:
                            if operation in ('INSERT', 'UPDATE'):
                                cdc_event['after'] = data
                            if operation == 'UPDATE':
                                cdc_event['before'] = {}  # Would need SQL_UNDO for this
                            if operation == 'DELETE':
                                cdc_event['before'] = data
                        
                        # Send to Kafka
                        topic = f"cdc.crm.{table_name.lower()}"
                        key = row_id if row_id else None
                        
                        future = self.kafka_producer.send(
                            topic=topic,
                            key=key,
                            value=cdc_event
                        )
                        
                        # Update checkpoint
                        self.checkpoints[table_name] = scn
                        
                    logger.info(f"Processed {len(changes)} changes for {table_name}")
                    
                else:
                    # No changes, wait a bit
                    time.sleep(1)
                    
        except Exception as e:
            logger.error(f"Error processing table {table_name}: {e}")
            # Continue processing other tables
        finally:
            cursor.close()
            
    def _map_operation(self, operation):
        """Map Oracle operation to CDC operation code"""
        mapping = {
            'INSERT': 'c',  # create
            'UPDATE': 'u',  # update
            'DELETE': 'd'   # delete
        }
        return mapping.get(operation, 'r')
        
    def _parse_sql_redo(self, sql_redo, operation):
        """Parse SQL_REDO to extract column values"""
        # This is a simplified parser
        # In production, you would use a proper SQL parser
        data = {}
        
        try:
            if operation == 'INSERT':
                # Extract values from INSERT statement
                # INSERT INTO "SCHEMA"."TABLE" ("COL1","COL2") VALUES ('VAL1','VAL2');
                if 'VALUES' in sql_redo:
                    # Basic parsing - would need enhancement for production
                    pass
                    
            elif operation == 'UPDATE':
                # Extract SET values from UPDATE statement
                # UPDATE "SCHEMA"."TABLE" SET "COL1" = 'VAL1' WHERE ...
                if 'SET' in sql_redo:
                    # Basic parsing - would need enhancement for production
                    pass
                    
            elif operation == 'DELETE':
                # Extract WHERE clause values
                # DELETE FROM "SCHEMA"."TABLE" WHERE "COL1" = 'VAL1'
                if 'WHERE' in sql_redo:
                    # Basic parsing - would need enhancement for production
                    pass
                    
        except Exception as e:
            logger.error(f"Error parsing SQL: {e}")
            
        return data
        
    def run(self):
        """Main run loop"""
        # Setup connections
        self.connect_oracle()
        self.setup_kafka()
        self.setup_logminer()
        
        # Process each table in parallel
        futures = []
        for table in TABLES_TO_MONITOR:
            future = self.executor.submit(self.process_table_changes, table)
            futures.append(future)
            
        # Wait for all threads
        try:
            for future in as_completed(futures):
                result = future.result()
        except KeyboardInterrupt:
            logger.info("Received interrupt signal")
            self.shutdown()
            
    def shutdown(self):
        """Graceful shutdown"""
        logger.info("Shutting down CDC producer...")
        self.running = False
        
        # Close Kafka producer
        if self.kafka_producer:
            self.kafka_producer.flush()
            self.kafka_producer.close()
            
        # Stop LogMiner
        if self.oracle_conn:
            try:
                cursor = self.oracle_conn.cursor()
                cursor.execute("BEGIN DBMS_LOGMNR.END_LOGMNR; END;")
                cursor.close()
            except:
                pass
                
        # Close Oracle connection
        if self.oracle_conn:
            self.oracle_conn.close()
            
        # Shutdown executor
        self.executor.shutdown(wait=True)
        
        logger.info("CDC producer shutdown complete")

def main():
    # Signal handlers
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