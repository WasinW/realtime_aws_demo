#!/usr/bin/env python3
"""
Generate mock data for S_CONTACT table
Creates 100k realistic contact records
"""

import cx_Oracle
import random
import string
from datetime import datetime, timedelta
from faker import Faker
import sys

# Configuration
ORACLE_DSN = sys.argv[1] if len(sys.argv) > 1 else "localhost:1521/CDCDEMO"
ORACLE_USER = "demo_user"
ORACLE_PASSWORD = "DemoUser123!"

fake = Faker()

def generate_row_id():
    """Generate Siebel-style ROW_ID"""
    return '1-' + ''.join(random.choices(string.ascii_uppercase + string.digits, k=7))

def generate_contacts(conn, num_records=100000):
    """Generate contact records"""
    cursor = conn.cursor()
    
    print(f"Generating {num_records} contact records...")
    
    batch_size = 1000
    contacts = []
    
    for i in range(num_records):
        # Generate realistic data
        contact = {
            'row_id': generate_row_id(),
            'fst_name': fake.first_name(),
            'last_name': fake.last_name(),
            'mid_name': fake.first_name() if random.random() > 0.7 else None,
            'birth_dt': fake.date_of_birth(minimum_age=18, maximum_age=80),
            'soc_security_num': fake.ssn() if random.random() > 0.5 else None,
            'email_addr': fake.email(),
            'work_ph_num': fake.phone_number()[:40],
            'cell_ph_num': fake.phone_number()[:40] if random.random() > 0.3 else None,
            'home_ph_num': fake.phone_number()[:40] if random.random() > 0.7 else None,
            'addr': fake.street_address()[:200],
            'city': fake.city()[:50],
            'state': fake.state_abbr(),
            'postal_cd': fake.postcode()[:30],
            'country': fake.country_code(),
            'contact_stat_cd': random.choice(['Active', 'Active', 'Active', 'Inactive']),
            'integration_id': f'CONT-{i+1:08d}',
            'person_uid': fake.uuid4(),
            'suppress_email_flg': random.choice(['Y', 'N', 'N', 'N']),
            'suppress_call_flg': random.choice(['Y', 'N', 'N', 'N'])
        }
        
        contacts.append(contact)
        
        # Insert in batches
        if len(contacts) >= batch_size:
            insert_batch(cursor, contacts)
            contacts = []
            
            if (i + 1) % 10000 == 0:
                print(f"Generated {i + 1} records...")
                conn.commit()
    
    # Insert remaining records
    if contacts:
        insert_batch(cursor, contacts)
        
    conn.commit()
    cursor.close()
    
    print(f"Successfully generated {num_records} contact records")

def insert_batch(cursor, contacts):
    """Insert a batch of contacts"""
    sql = """
        INSERT INTO S_CONTACT (
            ROW_ID, FST_NAME, LAST_NAME, MID_NAME, BIRTH_DT,
            SOC_SECURITY_NUM, EMAIL_ADDR, WORK_PH_NUM, CELL_PH_NUM, HOME_PH_NUM,
            ADDR, CITY, STATE, POSTAL_CD, COUNTRY,
            CONTACT_STAT_CD, INTEGRATION_ID, PERSON_UID,
            SUPPRESS_EMAIL_FLG, SUPPRESS_CALL_FLG
        ) VALUES (
            :row_id, :fst_name, :last_name, :mid_name, :birth_dt,
            :soc_security_num, :email_addr, :work_ph_num, :cell_ph_num, :home_ph_num,
            :addr, :city, :state, :postal_cd, :country,
            :contact_stat_cd, :integration_id, :person_uid,
            :suppress_email_flg, :suppress_call_flg
        )
    """
    
    cursor.executemany(sql, contacts)

def main():
    """Main function"""
    print("Connecting to Oracle database...")
    
    try:
        # Connect to Oracle
        conn = cx_Oracle.connect(
            user=ORACLE_USER,
            password=ORACLE_PASSWORD,
            dsn=ORACLE_DSN
        )
        
        print("Connected successfully")
        
        # Generate data
        generate_contacts(conn, 100000)
        
        # Show count
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) FROM S_CONTACT")
        count = cursor.fetchone()[0]
        print(f"\nTotal records in S_CONTACT: {count:,}")
        
        cursor.close()
        conn.close()
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()