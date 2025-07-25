# applications/kafka-producer/producer.py
import json
import time
import random
import logging
import argparse
from datetime import datetime
from typing import Dict, Any
from faker import Faker
from kafka import KafkaProducer
from kafka.errors import KafkaError
import boto3

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Initialize Faker for generating test data
fake = Faker()


class CDCProducer:
    def __init__(self, bootstrap_servers: str, topic_prefix: str = "oracle.inventory"):
        """Initialize Kafka producer with MSK IAM authentication"""
        self.topic_prefix = topic_prefix
        self.producer = KafkaProducer(
            bootstrap_servers=bootstrap_servers,
            value_serializer=lambda v: json.dumps(v).encode('utf-8'),
            key_serializer=lambda k: k.encode('utf-8') if k else None,
            security_protocol='SASL_SSL',
            sasl_mechanism='AWS_MSK_IAM',
            sasl_plain_username='aws',
            sasl_plain_password='aws',
            api_version=(2, 5, 0),
            retries=3,
            max_in_flight_requests_per_connection=1,
            compression_type='lz4',
            batch_size=16384,
            linger_ms=100
        )
        
        # Initialize customer and product caches
        self.customers = {}
        self.products = {}
        self.order_counter = 1000
        
    def generate_cdc_message(self, operation: str, before: Dict, after: Dict, 
                           table_name: str, schema_name: str = "DEMO_USER") -> Dict:
        """Generate a CDC message in Debezium format"""
        return {
            "schema": {
                "type": "struct",
                "fields": [
                    {"type": "struct", "fields": [], "optional": True, "name": "before"},
                    {"type": "struct", "fields": [], "optional": True, "name": "after"},
                    {"type": "struct", "fields": [], "optional": False, "name": "source"},
                    {"type": "string", "optional": False, "field": "op"},
                    {"type": "int64", "optional": True, "field": "ts_ms"}
                ]
            },
            "payload": {
                "before": before,
                "after": after,
                "source": {
                    "version": "2.5.1.Final",
                    "connector": "oracle",
                    "name": "oracle-server",
                    "ts_ms": int(time.time() * 1000),
                    "snapshot": "false",
                    "db": "ORCLCDB",
                    "schema": schema_name,
                    "table": table_name,
                    "scn": str(random.randint(1000000, 9999999))
                },
                "op": operation,
                "ts_ms": int(time.time() * 1000),
                "transaction": None
            }
        }
    
    def generate_customer(self, customer_id: int = None) -> Dict:
        """Generate a customer record"""
        if customer_id is None:
            customer_id = random.randint(1, 100000)
            
        return {
            "customer_id": customer_id,
            "first_name": fake.first_name(),
            "last_name": fake.last_name(),
            "email": fake.email(),
            "phone": fake.phone_number(),
            "ssn": fake.ssn(),
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat()
        }
    
    def generate_product(self, product_id: int = None) -> Dict:
        """Generate a product record"""
        if product_id is None:
            product_id = random.randint(1, 10000)
            
        categories = ["Electronics", "Clothing", "Food", "Books", "Home", "Sports", "Toys"]
        
        return {
            "product_id": product_id,
            "product_name": fake.catch_phrase(),
            "category": random.choice(categories),
            "price": round(random.uniform(10.0, 1000.0), 2),
            "stock_quantity": random.randint(0, 1000),
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat()
        }
    
    def generate_order(self, customer_id: int) -> Dict:
        """Generate an order record"""
        self.order_counter += 1
        
        return {
            "order_id": self.order_counter,
            "customer_id": customer_id,
            "order_date": datetime.now().isoformat(),
            "total_amount": round(random.uniform(50.0, 5000.0), 2),
            "status": random.choice(["PENDING", "PROCESSING", "SHIPPED", "DELIVERED", "CANCELLED"]),
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat()
        }
    
    def send_insert(self, table: str, record: Dict):
        """Send an INSERT CDC event"""
        topic = f"{self.topic_prefix}.{table}"
        key = f"{table}_{record.get(f'{table[:-1]}_id', record.get('order_id'))}"
        
        message = self.generate_cdc_message(
            operation="c",
            before=None,
            after=record,
            table_name=table.upper()
        )
        
        try:
            future = self.producer.send(topic, key=key, value=message)
            record_metadata = future.get(timeout=10)
            logger.info(f"INSERT sent to {topic} partition {record_metadata.partition} offset {record_metadata.offset}")
        except KafkaError as e:
            logger.error(f"Error sending INSERT to {topic}: {e}")
    
    def send_update(self, table: str, before: Dict, after: Dict):
        """Send an UPDATE CDC event"""
        topic = f"{self.topic_prefix}.{table}"
        key = f"{table}_{after.get(f'{table[:-1]}_id', after.get('order_id'))}"
        
        message = self.generate_cdc_message(
            operation="u",
            before=before,
            after=after,
            table_name=table.upper()
        )
        
        try:
            future = self.producer.send(topic, key=key, value=message)
            record_metadata = future.get(timeout=10)
            logger.info(f"UPDATE sent to {topic} partition {record_metadata.partition} offset {record_metadata.offset}")
        except KafkaError as e:
            logger.error(f"Error sending UPDATE to {topic}: {e}")
    
    def send_delete(self, table: str, record: Dict):
        """Send a DELETE CDC event"""
        topic = f"{self.topic_prefix}.{table}"
        key = f"{table}_{record.get(f'{table[:-1]}_id', record.get('order_id'))}"
        
        message = self.generate_cdc_message(
            operation="d",
            before=record,
            after=None,
            table_name=table.upper()
        )
        
        try:
            future = self.producer.send(topic, key=key, value=message)
            record_metadata = future.get(timeout=10)
            logger.info(f"DELETE sent to {topic} partition {record_metadata.partition} offset {record_metadata.offset}")
        except KafkaError as e:
            logger.error(f"Error sending DELETE to {topic}: {e}")
    
    def simulate_customer_lifecycle(self):
        """Simulate customer lifecycle: create, update, order"""
        # Create new customer
        customer = self.generate_customer()
        self.customers[customer['customer_id']] = customer
        self.send_insert('customers', customer)
        
        # Sometimes update customer info
        if random.random() > 0.7:
            old_customer = customer.copy()
            customer['email'] = fake.email()
            customer['updated_at'] = datetime.now().isoformat()
            self.send_update('customers', old_customer, customer)
            self.customers[customer['customer_id']] = customer
        
        # Create order for customer
        if random.random() > 0.3:
            order = self.generate_order(customer['customer_id'])
            self.send_insert('orders', order)
    
    def simulate_product_lifecycle(self):
        """Simulate product lifecycle: create, update stock"""
        # Create new product
        product = self.generate_product()
        self.products[product['product_id']] = product
        self.send_insert('products', product)
        
        # Update stock
        if random.random() > 0.5:
            old_product = product.copy()
            product['stock_quantity'] = random.randint(0, 1000)
            product['updated_at'] = datetime.now().isoformat()
            self.send_update('products', old_product, product)
            self.products[product['product_id']] = product
    
    def simulate_updates_on_existing(self):
        """Simulate updates on existing records"""
        # Update existing customer
        if self.customers and random.random() > 0.6:
            customer_id = random.choice(list(self.customers.keys()))
            old_customer = self.customers[customer_id].copy()
            new_customer = old_customer.copy()
            new_customer['phone'] = fake.phone_number()
            new_customer['updated_at'] = datetime.now().isoformat()
            self.send_update('customers', old_customer, new_customer)
            self.customers[customer_id] = new_customer
        
        # Update existing product
        if self.products and random.random() > 0.5:
            product_id = random.choice(list(self.products.keys()))
            old_product = self.products[product_id].copy()
            new_product = old_product.copy()
            new_product['price'] = round(random.uniform(10.0, 1000.0), 2)
            new_product['updated_at'] = datetime.now().isoformat()
            self.send_update('products', old_product, new_product)
            self.products[product_id] = new_product
    
    def run_simulation(self, duration_seconds: int = 300, events_per_second: int = 10):
        """Run the CDC simulation"""
        logger.info(f"Starting CDC simulation for {duration_seconds} seconds at {events_per_second} events/second")
        
        start_time = time.time()
        event_count = 0
        
        try:
            while time.time() - start_time < duration_seconds:
                batch_start = time.time()
                
                for _ in range(events_per_second):
                    operation = random.choice([
                        self.simulate_customer_lifecycle,
                        self.simulate_product_lifecycle,
                        self.simulate_updates_on_existing
                    ])
                    operation()
                    event_count += 1
                
                # Sleep to maintain rate
                elapsed = time.time() - batch_start
                if elapsed < 1.0:
                    time.sleep(1.0 - elapsed)
                
                if event_count % 100 == 0:
                    logger.info(f"Sent {event_count} events...")
                    
        except KeyboardInterrupt:
            logger.info("Simulation interrupted by user")
        finally:
            self.producer.flush()
            self.producer.close()
            logger.info(f"Simulation complete. Total events sent: {event_count}")


def get_msk_bootstrap_servers(cluster_arn: str) -> str:
    """Get MSK bootstrap servers from cluster ARN"""
    client = boto3.client('kafka')
    
    response = client.get_bootstrap_brokers(ClusterArn=cluster_arn)
    return response['BootstrapBrokerStringSaslIam']


def main():
    parser = argparse.ArgumentParser(description='CDC Event Producer for MSK')
    parser.add_argument('--cluster-arn', required=True, help='MSK Cluster ARN')
    parser.add_argument('--duration', type=int, default=300, help='Duration in seconds')
    parser.add_argument('--rate', type=int, default=10, help='Events per second')
    parser.add_argument('--topic-prefix', default='oracle.inventory', help='Topic prefix')
    
    args = parser.parse_args()
    
    # Get bootstrap servers
    bootstrap_servers = get_msk_bootstrap_servers(args.cluster_arn)
    logger.info(f"Bootstrap servers: {bootstrap_servers}")
    
    # Create and run producer
    producer = CDCProducer(bootstrap_servers, args.topic_prefix)
    producer.run_simulation(args.duration, args.rate)


if __name__ == "__main__":
    main()

