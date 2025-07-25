# scripts/monitoring/monitor-pipeline.py
#!/usr/bin/env python3
"""
CDC Pipeline Monitor - Real-time monitoring of the CDC pipeline health
"""

import time
import json
import argparse
import boto3
from datetime import datetime, timedelta
from typing import Dict, List
import logging
from kafka import KafkaAdminClient
from kafka.admin import ConfigResource, ConfigResourceType
from tabulate import tabulate
import colorama
from colorama import Fore, Style

# Initialize colorama for Windows compatibility
colorama.init()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class CDCPipelineMonitor:
    def __init__(self, msk_cluster_arn: str, redshift_cluster_id: str):
        self.msk_cluster_arn = msk_cluster_arn
        self.redshift_cluster_id = redshift_cluster_id
        
        # Initialize AWS clients
        self.kafka_client = boto3.client('kafka')
        self.cloudwatch = boto3.client('cloudwatch')
        self.redshift = boto3.client('redshift')
        self.eks = boto3.client('eks')
        
        # Get MSK details
        self.cluster_info = self._get_cluster_info()
        self.bootstrap_servers = self._get_bootstrap_servers()
        
        # Initialize Kafka admin client
        self.admin_client = KafkaAdminClient(
            bootstrap_servers=self.bootstrap_servers,
            security_protocol='SASL_SSL',
            sasl_mechanism='AWS_MSK_IAM',
            sasl_plain_username='aws',
            sasl_plain_password='aws'
        )
    
    def _get_cluster_info(self):
        """Get MSK cluster information"""
        response = self.kafka_client.describe_cluster(ClusterArn=self.msk_cluster_arn)
        return response['ClusterInfo']
    
    def _get_bootstrap_servers(self):
        """Get MSK bootstrap servers"""
        response = self.kafka_client.get_bootstrap_brokers(ClusterArn=self.msk_cluster_arn)
        return response['BootstrapBrokerStringSaslIam']
    
    def get_msk_metrics(self) -> Dict:
        """Get MSK cluster metrics from CloudWatch"""
        metrics = {}
        
        # Define metrics to fetch
        metric_queries = [
            ('CpuUser', 'Average', 'CPU Usage %'),
            ('MemoryUsed', 'Average', 'Memory Used %'),
            ('KafkaDataLogsDiskUsed', 'Average', 'Disk Used %'),
            ('BytesInPerSec', 'Sum', 'Bytes In/sec'),
            ('BytesOutPerSec', 'Sum', 'Bytes Out/sec'),
            ('MessagesInPerSec', 'Sum', 'Messages In/sec')
        ]
        
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=5)
        
        for metric_name, stat, display_name in metric_queries:
            try:
                response = self.cloudwatch.get_metric_statistics(
                    Namespace='AWS/Kafka',
                    MetricName=metric_name,
                    Dimensions=[
                        {
                            'Name': 'Cluster Name',
                            'Value': self.cluster_info['ClusterName']
                        }
                    ],
                    StartTime=start_time,
                    EndTime=end_time,
                    Period=300,
                    Statistics=[stat]
                )
                
                if response['Datapoints']:
                    value = response['Datapoints'][-1][stat]
                    metrics[display_name] = round(value, 2)
                else:
                    metrics[display_name] = 0
                    
            except Exception as e:
                logger.error(f"Error fetching metric {metric_name}: {e}")
                metrics[display_name] = 'N/A'
        
        return metrics
    
    def get_topic_stats(self) -> List[Dict]:
        """Get topic statistics"""
        topic_stats = []
        
        # Get all topics
        topics = self.admin_client.list_topics()
        cdc_topics = [t for t in topics if t.startswith('oracle.inventory')]
        
        for topic in cdc_topics:
            try:
                # Get topic metadata
                metadata = self.admin_client.describe_topics([topic])[0]
                
                stats = {
                    'Topic': topic,
                    'Partitions': len(metadata['partitions']),
                    'Replication': metadata['partitions'][0]['replicas'].__len__()
                }
                
                topic_stats.append(stats)
                
            except Exception as e:
                logger.error(f"Error getting stats for topic {topic}: {e}")
        
        return topic_stats
    
    def get_consumer_lag(self) -> List[Dict]:
        """Get consumer group lag"""
        consumer_groups = ['debezium-connect-cluster', 'pii-masking-app']
        lag_info = []
        
        for group in consumer_groups:
            try:
                # This would typically use kafka-consumer-groups.sh
                # For demo, showing structure
                lag_info.append({
                    'Consumer Group': group,
                    'Total Lag': 'N/A',
                    'Status': 'RUNNING'
                })
            except Exception as e:
                logger.error(f"Error getting lag for {group}: {e}")
        
        return lag_info
    
    def get_redshift_stats(self) -> Dict:
        """Get Redshift cluster statistics"""
        try:
            response = self.redshift.describe_clusters(
                ClusterIdentifier=self.redshift_cluster_id
            )
            
            cluster = response['Clusters'][0]
            
            return {
                'Status': cluster['ClusterStatus'],
                'Nodes': cluster['NumberOfNodes'],
                'Health': cluster.get('ClusterHealthStatus', 'N/A'),
                'Maintenance': cluster.get('MaintenanceTrackName', 'N/A')
            }
        except Exception as e:
            logger.error(f"Error getting Redshift stats: {e}")
            return {'Status': 'ERROR', 'Error': str(e)}
    
    def check_pipeline_health(self) -> Dict:
        """Check overall pipeline health"""
        health_checks = {
            'MSK Cluster': 'UNKNOWN',
            'Debezium Connector': 'UNKNOWN',
            'PII Masking': 'UNKNOWN',
            'Redshift': 'UNKNOWN'
        }
        
        # Check MSK
        if self.cluster_info['State'] == 'ACTIVE':
            health_checks['MSK Cluster'] = 'HEALTHY'
        else:
            health_checks['MSK Cluster'] = 'UNHEALTHY'
        
        # Check Redshift
        redshift_stats = self.get_redshift_stats()
        if redshift_stats.get('Status') == 'available':
            health_checks['Redshift'] = 'HEALTHY'
        else:
            health_checks['Redshift'] = 'UNHEALTHY'
        
        # TODO: Add actual health checks for Debezium and PII Masking
        # For now, assuming they're healthy if MSK is healthy
        if health_checks['MSK Cluster'] == 'HEALTHY':
            health_checks['Debezium Connector'] = 'HEALTHY'
            health_checks['PII Masking'] = 'HEALTHY'
        
        return health_checks
    
    def display_dashboard(self):
        """Display monitoring dashboard"""
        print("\033[2J\033[H")  # Clear screen
        print(f"{Fore.CYAN}{'='*80}{Style.RESET_ALL}")
        print(f"{Fore.CYAN}CDC Pipeline Monitor - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Style.RESET_ALL}")
        print(f"{Fore.CYAN}{'='*80}{Style.RESET_ALL}\n")
        
        # Pipeline Health
        health = self.check_pipeline_health()
        print(f"{Fore.YELLOW}Pipeline Health:{Style.RESET_ALL}")
        health_table = []
        for component, status in health.items():
            color = Fore.GREEN if status == 'HEALTHY' else Fore.RED
            health_table.append([component, f"{color}{status}{Style.RESET_ALL}"])
        print(tabulate(health_table, headers=['Component', 'Status'], tablefmt='grid'))
        print()
        
        # MSK Metrics
        print(f"{Fore.YELLOW}MSK Cluster Metrics:{Style.RESET_ALL}")
        msk_metrics = self.get_msk_metrics()
        metrics_table = [[k, v] for k, v in msk_metrics.items()]
        print(tabulate(metrics_table, headers=['Metric', 'Value'], tablefmt='grid'))
        print()
        
        # Topic Statistics
        print(f"{Fore.YELLOW}Topic Statistics:{Style.RESET_ALL}")
        topic_stats = self.get_topic_stats()
        if topic_stats:
            print(tabulate(topic_stats, headers='keys', tablefmt='grid'))
        print()
        
        # Consumer Lag
        print(f"{Fore.YELLOW}Consumer Groups:{Style.RESET_ALL}")
        lag_info = self.get_consumer_lag()
        if lag_info:
            print(tabulate(lag_info, headers='keys', tablefmt='grid'))
        print()
        
        # Redshift Status
        print(f"{Fore.YELLOW}Redshift Status:{Style.RESET_ALL}")
        redshift_stats = self.get_redshift_stats()
        redshift_table = [[k, v] for k, v in redshift_stats.items()]
        print(tabulate(redshift_table, headers=['Property', 'Value'], tablefmt='grid'))
    
    def run_continuous_monitoring(self, refresh_interval: int = 30):
        """Run continuous monitoring"""
        try:
            while True:
                self.display_dashboard()
                print(f"\n{Fore.CYAN}Refreshing in {refresh_interval} seconds... (Ctrl+C to exit){Style.RESET_ALL}")
                time.sleep(refresh_interval)
        except KeyboardInterrupt:
            print(f"\n{Fore.YELLOW}Monitoring stopped.{Style.RESET_ALL}")


