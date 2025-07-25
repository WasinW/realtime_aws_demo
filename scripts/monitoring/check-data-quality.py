# scripts/monitoring/check-data-quality.py
#!/usr/bin/env python3
"""
Data Quality Checker - Validates data consistency across the pipeline
"""

import json
import argparse
import psycopg2
import boto3
from datetime import datetime, timedelta
from typing import Dict, List, Tuple
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class DataQualityChecker:
    def __init__(self, redshift_config: Dict, oracle_config: Dict):
        self.redshift_config = redshift_config
        self.oracle_config = oracle_config
        self.validation_results = []
    
    def connect_redshift(self):
        """Connect to Redshift"""
        return psycopg2.connect(
            host=self.redshift_config['host'],
            port=self.redshift_config['port'],
            database=self.redshift_config['database'],
            user=self.redshift_config['user'],
            password=self.redshift_config['password']
        )
    
    def check_row_counts(self) -> List[Dict]:
        """Compare row counts between source and target"""
        results = []
        tables = ['customers', 'products', 'orders']
        
        with self.connect_redshift() as conn:
            cursor = conn.cursor()
            
            for table in tables:
                # Get Redshift count
                cursor.execute(f"""
                    SELECT COUNT(*) 
                    FROM marts.dim_{table} 
                    WHERE is_current = TRUE
                """)
                redshift_count = cursor.fetchone()[0]
                
                # Get latest CDC count
                cursor.execute(f"""
                    SELECT COUNT(DISTINCT change_data.after.{table[:-1]}_id)
                    FROM staging.{table}_stream
                    WHERE change_data.op IN ('c', 'u', 'r')
                """)
                cdc_count = cursor.fetchone()[0]
                
                results.append({
                    'table': table,
                    'redshift_count': redshift_count,
                    'cdc_count': cdc_count,
                    'difference': abs(redshift_count - cdc_count),
                    'match': redshift_count == cdc_count
                })
        
        return results
    
    def check_data_freshness(self) -> List[Dict]:
        """Check data freshness in Redshift"""
        results = []
        
        with self.connect_redshift() as conn:
            cursor = conn.cursor()
            
            tables = ['customers_stream', 'products_stream', 'orders_stream']
            
            for table in tables:
                cursor.execute(f"""
                    SELECT 
                        MAX(kafka_timestamp) as latest_record,
                        CURRENT_TIMESTAMP - MAX(kafka_timestamp) as lag
                    FROM staging.{table}
                """)
                
                row = cursor.fetchone()
                if row and row[0]:
                    results.append({
                        'table': table,
                        'latest_record': row[0],
                        'lag_seconds': row[1].total_seconds() if row[1] else None,
                        'status': 'OK' if row[1].total_seconds() < 300 else 'LAGGING'
                    })
        
        return results
    
    def check_pii_masking(self) -> List[Dict]:
        """Verify PII fields are properly masked"""
        results = []
        
        with self.connect_redshift() as conn:
            cursor = conn.cursor()
            
            # Check email masking
            cursor.execute("""
                SELECT COUNT(*) 
                FROM marts.dim_customers 
                WHERE is_current = TRUE 
                AND email NOT LIKE '%***%'
            """)
            unmasked_emails = cursor.fetchone()[0]
            
            # Check SSN tokenization
            cursor.execute("""
                SELECT COUNT(*) 
                FROM marts.dim_customers 
                WHERE is_current = TRUE 
                AND ssn_token NOT LIKE 'TOKEN-%'
            """)
            untokenized_ssns = cursor.fetchone()[0]
            
            results.append({
                'check': 'Email Masking',
                'unmasked_count': unmasked_emails,
                'status': 'PASS' if unmasked_emails == 0 else 'FAIL'
            })
            
            results.append({
                'check': 'SSN Tokenization',
                'untokenized_count': untokenized_ssns,
                'status': 'PASS' if untokenized_ssns == 0 else 'FAIL'
            })
        
        return results
    
    def check_duplicate_processing(self) -> List[Dict]:
        """Check for duplicate CDC events"""
        results = []
        
        with self.connect_redshift() as conn:
            cursor = conn.cursor()
            
            tables = ['customers', 'products', 'orders']
            
            for table in tables:
                cursor.execute(f"""
                    WITH duplicates AS (
                        SELECT 
                            kafka_partition,
                            kafka_offset,
                            COUNT(*) as dup_count
                        FROM staging.{table}_stream
                        GROUP BY kafka_partition, kafka_offset
                        HAVING COUNT(*) > 1
                    )
                    SELECT COUNT(*) FROM duplicates
                """)
                
                duplicate_count = cursor.fetchone()[0]
                
                results.append({
                    'table': table,
                    'duplicate_events': duplicate_count,
                    'status': 'PASS' if duplicate_count == 0 else 'FAIL'
                })
        
        return results
    
    def generate_quality_report(self) -> Dict:
        """Generate comprehensive data quality report"""
        report = {
            'timestamp': datetime.now().isoformat(),
            'checks': {
                'row_counts': self.check_row_counts(),
                'data_freshness': self.check_data_freshness(),
                'pii_masking': self.check_pii_masking(),
                'duplicates': self.check_duplicate_processing()
            }
        }
        
        # Calculate overall health score
        total_checks = 0
        passed_checks = 0
        
        for check_type, checks in report['checks'].items():
            for check in checks:
                total_checks += 1
                if check.get('status') == 'PASS' or check.get('match', False):
                    passed_checks += 1
        
        report['health_score'] = round((passed_checks / total_checks) * 100, 2)
        report['status'] = 'HEALTHY' if report['health_score'] >= 90 else 'NEEDS_ATTENTION'
        
        return report


def main():
    parser = argparse.ArgumentParser(description='CDC Pipeline Data Quality Checker')
    parser.add_argument('--redshift-host', required=True, help='Redshift host')
    parser.add_argument('--redshift-user', default='admin', help='Redshift user')
    parser.add_argument('--redshift-password', required=True, help='Redshift password')
    parser.add_argument('--output', default='quality-report.json', help='Output file')
    
    args = parser.parse_args()
    
    redshift_config = {
        'host': args.redshift_host,
        'port': 5439,
        'database': 'cdcdemo',
        'user': args.redshift_user,
        'password': args.redshift_password
    }
    
    # Oracle config not used in this demo version
    oracle_config = {}
    
    checker = DataQualityChecker(redshift_config, oracle_config)
    report = checker.generate_quality_report()
    
    # Print summary
    print(f"Data Quality Report - {report['timestamp']}")
    print(f"Overall Health Score: {report['health_score']}%")
    print(f"Status: {report['status']}")
    
    # Save detailed report
    with open(args.output, 'w') as f:
        json.dump(report, f, indent=2, default=str)
    
    print(f"\nDetailed report saved to: {args.output}")


if __name__ == "__main__":
    main()


# requirements.txt for monitoring scripts
boto3>=1.26.0
psycopg2-binary>=2.9.0
kafka-python>=2.0.2
tabulate>=0.9.0
colorama>=0.4.6