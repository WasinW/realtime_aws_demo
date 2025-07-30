-- Create schema
CREATE SCHEMA IF NOT EXISTS cdc;

-- Create S_CONTACT table in Redshift
CREATE TABLE cdc.s_contact (
    -- Original Oracle columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    
    -- Contact Information
    fst_name            VARCHAR(50),
    last_name           VARCHAR(50) NOT NULL,
    mid_name            VARCHAR(50),
    birth_dt            DATE,
    soc_security_num    VARCHAR(40),
    
    -- Contact Details
    email_addr          VARCHAR(350),
    work_ph_num         VARCHAR(40),
    cell_ph_num         VARCHAR(40),
    home_ph_num         VARCHAR(40),
    
    -- Address Information
    addr                VARCHAR(200),
    city                VARCHAR(50),
    state               VARCHAR(50),
    postal_cd           VARCHAR(30),
    country             VARCHAR(30),
    
    -- Status
    contact_stat_cd     VARCHAR(30),
    
    -- Integration
    integration_id      VARCHAR(30),
    
    -- Additional Siebel fields
    pr_dept_ou_id       VARCHAR(15),
    pr_postn_id         VARCHAR(15),
    person_uid          VARCHAR(100),
    suppress_email_flg  CHAR(1),
    suppress_call_flg   CHAR(1),
    
    -- CDC timestamp columns
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    
    -- Primary key including CDC timestamp for versioning
    PRIMARY KEY (row_id, kafka_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (kafka_timestamp);

-- Create staging table for COPY operations
CREATE TABLE cdc.s_contact_staging (LIKE cdc.s_contact);

-- Create view for current records
CREATE VIEW cdc.v_s_contact_current AS
WITH ranked_contacts AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY kafka_timestamp DESC) as rn
    FROM cdc.s_contact
)
SELECT * FROM ranked_contacts WHERE rn = 1;

-- Grant permissions
GRANT USAGE ON SCHEMA cdc TO GROUP data_readers;
GRANT SELECT ON ALL TABLES IN SCHEMA cdc TO GROUP data_readers;