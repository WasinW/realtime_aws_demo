#!/usr/bin/env python3
"""
Generate mock CRM data for Oracle database
Creates realistic Siebel CRM-like data
"""

import os
import sys
import random
import string
from datetime import datetime, timedelta
import cx_Oracle
from faker import Faker

# Configuration
ORACLE_DSN = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('ORACLE_ENDPOINT')
ORACLE_USER = sys.argv[2] if len(sys.argv) > 2 else 'admin'
ORACLE_PASSWORD = sys.argv[3] if len(sys.argv) > 3 else os.environ.get('ORACLE_PASSWORD')

fake = Faker()

def generate_row_id():
    """Generate Siebel-style ROW_ID"""
    return '1-' + ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))

def generate_crm_data(connection):
    """Generate CRM data"""
    cursor = connection.cursor()
    
    print("Generating CRM data...")
    
    # Generate contacts
    print("Generating contacts...")
    contacts = []
    for i in range(20000):
        row_id = generate_row_id()
        contacts.append(row_id)
        
        data = {
            'row_id': row_id,
            'created_by': '0-1',
            'last_upd_by': '0-1',
            'fst_name': fake.first_name(),
            'last_name': fake.last_name(),
            'mid_name': fake.first_name() if random.random() > 0.5 else None,
            'email_addr': fake.email(),
            'work_ph_num': fake.phone_number()[:40],
            'cell_ph_num': fake.phone_number()[:40] if random.random() > 0.3 else None,
            'home_ph_num': fake.phone_number()[:40] if random.random() > 0.7 else None,
            'birth_dt': fake.date_of_birth(minimum_age=18, maximum_age=80),
            'marital_stat_cd': random.choice(['SINGLE', 'MARRIED', 'DIVORCED', 'WIDOWED']),
            'integration_id': f'CONT-{i+1:06d}',
            'status_cd': random.choice(['ACTIVE', 'ACTIVE', 'ACTIVE', 'INACTIVE'])
        }
        
        data['full_name'] = f"{data['fst_name']} {data['last_name']}"
        
        cursor.execute("""
            INSERT INTO crm_user.s_contact (
                row_id, created_by, last_upd_by, fst_name, last_name,
                mid_name, full_name, email_addr, work_ph_num, cell_ph_num,
                home_ph_num, birth_dt, marital_stat_cd, integration_id, status_cd
            ) VALUES (
                :row_id, :created_by, :last_upd_by, :fst_name, :last_name,
                :mid_name, :full_name, :email_addr, :work_ph_num, :cell_ph_num,
                :home_ph_num, :birth_dt, :marital_stat_cd, :integration_id, :status_cd
            )
        """, data)
        
        if (i + 1) % 1000 == 0:
            connection.commit()
            print(f"  Generated {i + 1} contacts")
    
    # Generate organizations
    print("Generating organizations...")
    orgs = []
    for i in range(5000):
        row_id = generate_row_id()
        orgs.append(row_id)
        
        data = {
            'row_id': row_id,
            'created_by': '0-1',
            'last_upd_by': '0-1',
            'name': fake.company(),
            'loc': fake.city(),
            'ou_type_cd': random.choice(['CUSTOMER', 'PROSPECT', 'PARTNER']),
            'cust_stat_cd': random.choice(['ACTIVE', 'ACTIVE', 'INACTIVE']),
            'accnt_type_cd': random.choice(['ENTERPRISE', 'SMB', 'STARTUP']),
            'num_employees': random.randint(10, 10000),
            'annual_rev': random.randint(100000, 1000000000),
            'annual_rev_curcy_cd': 'USD',
            'integration_id': f'ACCT-{i+1:06d}',
            'status_cd': 'ACTIVE'
        }
        
        cursor.execute("""
            INSERT INTO crm_user.s_org_ext (
                row_id, created_by, last_upd_by, name, loc,
                ou_type_cd, cust_stat_cd, accnt_type_cd,
                num_employees, annual_rev, annual_rev_curcy_cd,
                integration_id, status_cd
            ) VALUES (
                :row_id, :created_by, :last_upd_by, :name, :loc,
                :ou_type_cd, :cust_stat_cd, :accnt_type_cd,
                :num_employees, :annual_rev, :annual_rev_curcy_cd,
                :integration_id, :status_cd
            )
        """, data)
        
        if (i + 1) % 500 == 0:
            connection.commit()
            print(f"  Generated {i + 1} organizations")
    
    # Generate opportunities
    print("Generating opportunities...")
    optys = []
    for i in range(15000):
        row_id = generate_row_id()
        optys.append(row_id)
        
        data = {
            'row_id': row_id,
            'created_by': '0-1',
            'last_upd_by': '0-1',
            'name': f"{fake.bs()} Opportunity",
            'type_cd': random.choice(['NEW_BUSINESS', 'RENEWAL', 'EXPANSION']),
            'accnt_id': random.choice(orgs),
            'pr_con_id': random.choice(contacts),
            'curcy_cd': 'USD',
            'eff_start_dt': fake.date_between(start_date='-1y', end_date='today'),
            'close_dt': fake.date_between(start_date='today', end_date='+6m'),
            'sum_revn_amt': random.randint(10000, 5000000),
            'sum_win_prob': random.randint(10, 90),
            'stg_status_cd': random.choice(['PROSPECTING', 'QUALIFICATION', 'PROPOSAL', 'NEGOTIATION', 'CLOSED_WON', 'CLOSED_LOST']),
            'integration_id': f'OPTY-{i+1:06d}',
            'status_cd': 'ACTIVE'
        }
        
        cursor.execute("""
            INSERT INTO crm_user.s_opty (
                row_id, created_by, last_upd_by, name, type_cd,
                accnt_id, pr_con_id, curcy_cd, eff_start_dt,
                close_dt, sum_revn_amt, sum_win_prob, stg_status_cd,
                integration_id, status_cd
            ) VALUES (
                :row_id, :created_by, :last_upd_by, :name, :type_cd,
                :accnt_id, :pr_con_id, :curcy_cd, :eff_start_dt,
                :close_dt, :sum_revn_amt, :sum_win_prob, :stg_status_cd,
                :integration_id, :status_cd
            )
        """, data)
        
        if (i + 1) % 1000 == 0:
            connection.commit()
            print(f"  Generated {i + 1} opportunities")
    
    # Generate orders
    print("Generating orders...")
    orders = []
    for i in range(30000):
        row_id = generate_row_id()
        orders.append(row_id)
        
        data = {
            'row_id': row_id,
            'created_by': '0-1',
            'last_upd_by': '0-1',
            'order_num': f'ORD-{datetime.now().year}-{i+1:06d}',
            'order_dt': fake.date_between(start_date='-1y', end_date='today'),
            'order_type_cd': random.choice(['SALES_ORDER', 'QUOTE', 'SERVICE_ORDER']),
            'accnt_id': random.choice(orgs),
            'contact_id': random.choice(contacts),
            'opty_id': random.choice(optys) if random.random() > 0.3 else None,
            'curcy_cd': 'USD',
            'status_cd': random.choice(['PENDING', 'APPROVED', 'SHIPPED', 'COMPLETED', 'CANCELLED']),
            'payment_type_cd': random.choice(['CREDIT_CARD', 'INVOICE', 'WIRE_TRANSFER']),
            'integration_id': f'ORD-{i+1:06d}'
        }
        
        # Calculate order totals
        subtotal = random.randint(1000, 100000)
        tax = subtotal * 0.08
        freight = random.randint(50, 500)
        
        data['freight_amt'] = freight
        data['tax_amt'] = tax
        data['item_total'] = subtotal
        data['order_total'] = subtotal + tax + freight
        
        cursor.execute("""
            INSERT INTO crm_user.s_order (
                row_id, created_by, last_upd_by, order_num, order_dt,
                order_type_cd, accnt_id, contact_id, opty_id, curcy_cd,
                freight_amt, tax_amt, item_total, order_total,
                status_cd, payment_type_cd, integration_id
            ) VALUES (
                :row_id, :created_by, :last_upd_by, :order_num, :order_dt,
                :order_type_cd, :accnt_id, :contact_id, :opty_id, :curcy_cd,
                :freight_amt, :tax_amt, :item_total, :order_total,
                :status_cd, :payment_type_cd, :integration_id
            )
        """, data)
        
        # Generate order items
        num_items = random.randint(1, 10)
        for j in range(num_items):
            item_data = {
                'row_id': generate_row_id(),
                'created_by': '0-1',
                'last_upd_by': '0-1',
                'order_id': row_id,
                'line_num': j + 1,
                'prod_name': fake.bs(),
                'part_num': f'PART-{random.randint(1000, 9999)}',
                'qty': random.randint(1, 100),
                'unit_price': random.randint(10, 1000),
                'discount_percent': random.choice([0, 0, 0, 5, 10, 15, 20]),
                'status_cd': 'ACTIVE',
                'integration_id': f'ITEM-{i+1:06d}-{j+1:02d}'
            }
            
            # Calculate line total
            extended = item_data['qty'] * item_data['unit_price']
            discount = extended * item_data['discount_percent'] / 100
            item_data['extended_amt'] = extended
            item_data['discount_amt'] = discount
            item_data['line_total'] = extended - discount
            
            cursor.execute("""
                INSERT INTO crm_user.s_order_item (
                    row_id, created_by, last_upd_by, order_id, line_num,
                    prod_name, part_num, qty, unit_price, extended_amt,
                    discount_amt, discount_percent, line_total,
                    status_cd, integration_id
                ) VALUES (
                    :row_id, :created_by, :last_upd_by, :order_id, :line_num,
                    :prod_name, :part_num, :qty, :unit_price, :extended_amt,
                    :discount_amt, :discount_percent, :line_total,
                    :status_cd, :integration_id
                )
            """, item_data)
        
        if (i + 1) % 1000 == 0:
            connection.commit()
            print(f"  Generated {i + 1} orders")
    
    # Generate activities
    print("Generating activities...")
    for i in range(20000):
        data = {
            'row_id': generate_row_id(),
            'created_by': '0-1',
            'last_upd_by': '0-1',
            'activity_uid': f'ACT-{i+1:08d}',
            'type_cd': random.choice(['CALL', 'MEETING', 'EMAIL', 'TASK', 'DEMO']),
            'pr_subject': fake.sentence(nb_words=6),
            'desc_text': fake.text(max_nb_chars=200),
            'accnt_id': random.choice(orgs) if random.random() > 0.3 else None,
            'contact_id': random.choice(contacts) if random.random() > 0.3 else None,
            'opty_id': random.choice(optys) if random.random() > 0.5 else None,
            'start_dt': fake.date_time_between(start_date='-1y', end_date='+1m'),
            'duration_min': random.choice([15, 30, 60, 90, 120]),
            'status_cd': random.choice(['PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED']),
            'priority_cd': random.choice(['HIGH', 'MEDIUM', 'LOW']),
            'integration_id': f'ACT-{i+1:06d}'
        }
        
        # Set end date based on duration
        if data['start_dt'] and data['duration_min']:
            data['end_dt'] = data['start_dt'] + timedelta(minutes=data['duration_min'])
        
        cursor.execute("""
            INSERT INTO crm_user.s_activity (
                row_id, created_by, last_upd_by, activity_uid, type_cd,
                pr_subject, desc_text, accnt_id, contact_id, opty_id,
                start_dt, end_dt, duration_min, status_cd, priority_cd,
                integration_id
            ) VALUES (
                :row_id, :created_by, :last_upd_by, :activity_uid, :type_cd,
                :pr_subject, :desc_text, :accnt_id, :contact_id, :opty_id,
                :start_dt, :end_dt, :duration_min, :status_cd, :priority_cd,
                :integration_id
            )
        """, data)
        
        if (i + 1) % 1000 == 0:
            connection.commit()
            print(f"  Generated {i + 1} activities")
    
    connection.commit()
    print("\nData generation complete!")
    
    # Show counts
    tables = [
        ('s_contact', 'contacts'),
        ('s_org_ext', 'organizations'),
        ('s_opty', 'opportunities'),
        ('s_order', 'orders'),
        ('s_order_item', 'order items'),
        ('s_activity', 'activities')
    ]
    
    print("\nGenerated data summary:")
    for table, name in tables:
        cursor.execute(f"SELECT COUNT(*) FROM crm_user.{table}")
        count = cursor.fetchone()[0]
        print(f"  {name}: {count:,}")
    
    cursor.close()

def main():
    if not ORACLE_DSN:
        print("Usage: python generate_crm_data.py <oracle_dsn> <username> <password>")
        sys.exit(1)
    
    print(f"Connecting to Oracle: {ORACLE_DSN}")
    
    try:
        # Connect to Oracle
        connection = cx_Oracle.connect(
            user=ORACLE_USER,
            password=ORACLE_PASSWORD,
            dsn=ORACLE_DSN
        )
        
        # Generate data
        generate_crm_data(connection)
        
        # Close connection
        connection.close()
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()