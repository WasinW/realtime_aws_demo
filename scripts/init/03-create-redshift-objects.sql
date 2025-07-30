-- Create schema
CREATE SCHEMA IF NOT EXISTS crm_cdc;

-- S_CONTACT replica with CDC timestamps
CREATE TABLE crm_cdc.s_contact (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    fst_name            VARCHAR(50),
    last_name           VARCHAR(50) NOT NULL,
    mid_name            VARCHAR(50),
    full_name           VARCHAR(150),
    emp_flg             CHAR(1),
    priv_flg            CHAR(1),
    suppress_email_flg  CHAR(1),
    suppress_call_flg   CHAR(1),
    email_addr          VARCHAR(350),
    work_ph_num         VARCHAR(40),
    cell_ph_num         VARCHAR(40),
    home_ph_num         VARCHAR(40),
    birth_dt            DATE,
    soc_security_num    VARCHAR(20),
    marital_stat_cd     VARCHAR(30),
    citizenship_cd      VARCHAR(30),
    nationality_cd      VARCHAR(30),
    pr_dept_ou_id       VARCHAR(15),
    pr_postn_id         VARCHAR(15),
    person_uid          VARCHAR(100),
    integration_id      VARCHAR(30),
    status_cd           VARCHAR(30),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (cdc_timestamp);

-- S_ORG_EXT replica with CDC timestamps
CREATE TABLE crm_cdc.s_org_ext (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    name                VARCHAR(100) NOT NULL,
    loc                 VARCHAR(50),
    ou_type_cd          VARCHAR(30),
    pr_terr_id          VARCHAR(15),
    cust_stat_cd        VARCHAR(30),
    partner_flg         CHAR(1),
    divn_type_cd        VARCHAR(30),
    accnt_type_cd       VARCHAR(30),
    duns_num            VARCHAR(15),
    sic_cd              VARCHAR(20),
    fiscal_yr_end_mo    VARCHAR(30),
    num_employees       INTEGER,
    annual_rev          DECIMAL(22,7),
    annual_rev_curcy_cd VARCHAR(20),
    integration_id      VARCHAR(30),
    status_cd           VARCHAR(30),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (cdc_timestamp);

-- S_OPTY replica with CDC timestamps
CREATE TABLE crm_cdc.s_opty (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    name                VARCHAR(100) NOT NULL,
    type_cd             VARCHAR(30),
    pr_prod_id          VARCHAR(15),
    accnt_id            VARCHAR(15),
    pr_con_id           VARCHAR(15),
    curcy_cd            VARCHAR(20),
    exch_dt             DATE,
    eff_start_dt        DATE,
    eff_end_dt          DATE,
    close_dt            DATE,
    sum_revn_amt        DECIMAL(22,7),
    sum_revn_curcy_cd   VARCHAR(20),
    sum_win_prob        DECIMAL(5,2),
    stg_status_cd       VARCHAR(30),
    lead_qual_cd        VARCHAR(30),
    pr_postn_id         VARCHAR(15),
    pr_terr_id          VARCHAR(15),
    integration_id      VARCHAR(30),
    opty_cd             VARCHAR(30),
    status_cd           VARCHAR(30),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (cdc_timestamp);

-- S_ORDER replica with CDC timestamps
CREATE TABLE crm_cdc.s_order (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    order_num           VARCHAR(30) NOT NULL,
    rev_num             INTEGER,
    order_dt            DATE,
    order_type_cd       VARCHAR(30),
    accnt_id            VARCHAR(15),
    contact_id          VARCHAR(15),
    opty_id             VARCHAR(15),
    curcy_cd            VARCHAR(20),
    exch_dt             DATE,
    ship_dt             DATE,
    req_ship_dt         DATE,
    freight_amt         DECIMAL(22,7),
    freight_curcy_cd    VARCHAR(20),
    tax_amt             DECIMAL(22,7),
    item_total          DECIMAL(22,7),
    order_total         DECIMAL(22,7),
    status_cd           VARCHAR(30),
    payment_term_cd     VARCHAR(30),
    payment_type_cd     VARCHAR(30),
    integration_id      VARCHAR(30),
    active_flg          CHAR(1),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (cdc_timestamp);

-- S_ORDER_ITEM replica with CDC timestamps
CREATE TABLE crm_cdc.s_order_item (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    order_id            VARCHAR(15) NOT NULL,
    line_num            INTEGER NOT NULL,
    prod_id             VARCHAR(15),
    prod_name           VARCHAR(100),
    part_num            VARCHAR(50),
    qty                 DECIMAL(22,7),
    qty_shipped         DECIMAL(22,7),
    unit_price          DECIMAL(22,7),
    unit_price_curcy_cd VARCHAR(20),
    extended_amt        DECIMAL(22,7),
    discount_amt        DECIMAL(22,7),
    discount_percent    DECIMAL(5,2),
    tax_amt             DECIMAL(22,7),
    line_total          DECIMAL(22,7),
    status_cd           VARCHAR(30),
    integration_id      VARCHAR(30),
    action_cd           VARCHAR(30),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (order_id)
SORTKEY (cdc_timestamp);

-- S_ACTIVITY replica with CDC timestamps
CREATE TABLE crm_cdc.s_activity (
    -- Original columns
    row_id              VARCHAR(15) NOT NULL,
    created             TIMESTAMP NOT NULL,
    created_by          VARCHAR(15) NOT NULL,
    last_upd            TIMESTAMP NOT NULL,
    last_upd_by         VARCHAR(15) NOT NULL,
    modification_num    INTEGER NOT NULL,
    conflict_id         VARCHAR(15) NOT NULL,
    activity_uid        VARCHAR(50),
    type_cd             VARCHAR(30),
    subtype_cd          VARCHAR(30),
    pr_subject          VARCHAR(250),
    desc_text           VARCHAR(2000),
    accnt_id            VARCHAR(15),
    contact_id          VARCHAR(15),
    opty_id             VARCHAR(15),
    start_dt            TIMESTAMP,
    end_dt              TIMESTAMP,
    duration_min        INTEGER,
    pr_emp_id           VARCHAR(15),
    status_cd           VARCHAR(30),
    priority_cd         VARCHAR(30),
    alarm_flag          CHAR(1),
    todo_plan_start_dt  DATE,
    todo_plan_end_dt    DATE,
    todo_actl_end_dt    DATE,
    integration_id      VARCHAR(30),
    active_flg          CHAR(1),
    -- CDC columns
    cdc_operation       VARCHAR(10),
    cdc_timestamp       TIMESTAMP,
    kafka_timestamp     TIMESTAMP,
    s3_write_timestamp  TIMESTAMP,
    -- Constraints
    PRIMARY KEY (row_id, cdc_timestamp)
)
DISTSTYLE KEY
DISTKEY (row_id)
SORTKEY (cdc_timestamp);

-- Create staging tables for COPY operations
CREATE TABLE crm_cdc.stg_s_contact (LIKE crm_cdc.s_contact);
CREATE TABLE crm_cdc.stg_s_org_ext (LIKE crm_cdc.s_org_ext);
CREATE TABLE crm_cdc.stg_s_opty (LIKE crm_cdc.s_opty);
CREATE TABLE crm_cdc.stg_s_order (LIKE crm_cdc.s_order);
CREATE TABLE crm_cdc.stg_s_order_item (LIKE crm_cdc.s_order_item);
CREATE TABLE crm_cdc.stg_s_activity (LIKE crm_cdc.s_activity);

-- Create views for current state (latest record per row_id)
CREATE VIEW crm_cdc.v_current_contacts AS
WITH ranked_contacts AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY cdc_timestamp DESC) as rn
    FROM crm_cdc.s_contact
    WHERE cdc_operation != 'DELETE'
)
SELECT * FROM ranked_contacts WHERE rn = 1;

CREATE VIEW crm_cdc.v_current_accounts AS
WITH ranked_accounts AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY cdc_timestamp DESC) as rn
    FROM crm_cdc.s_org_ext
    WHERE cdc_operation != 'DELETE'
)
SELECT * FROM ranked_accounts WHERE rn = 1;

CREATE VIEW crm_cdc.v_current_opportunities AS
WITH ranked_opps AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY cdc_timestamp DESC) as rn
    FROM crm_cdc.s_opty
    WHERE cdc_operation != 'DELETE'
)
SELECT * FROM ranked_opps WHERE rn = 1;

CREATE VIEW crm_cdc.v_current_orders AS
WITH ranked_orders AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY row_id ORDER BY cdc_timestamp DESC) as rn
    FROM crm_cdc.s_order
    WHERE cdc_operation != 'DELETE'
)
SELECT * FROM ranked_orders WHERE rn = 1;

-- Grant permissions
GRANT USAGE ON SCHEMA crm_cdc TO GROUP data_analysts;
GRANT SELECT ON ALL TABLES IN SCHEMA crm_cdc TO GROUP data_analysts;