-- Create schemas
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS marts;

-- Create target tables with CDC timestamps
CREATE TABLE marts.customers (
    customer_id INTEGER PRIMARY KEY,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    email VARCHAR(200),
    phone VARCHAR(20),
    created_date TIMESTAMP,
    updated_date TIMESTAMP,
    -- CDC timestamps
    consumed_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    written_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
DISTSTYLE KEY
DISTKEY (customer_id);

CREATE TABLE marts.products (
    product_id INTEGER PRIMARY KEY,
    product_name VARCHAR(200),
    category VARCHAR(100),
    price DECIMAL(10,2),
    stock_quantity INTEGER,
    created_date TIMESTAMP,
    updated_date TIMESTAMP,
    -- CDC timestamps
    consumed_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    written_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
DISTSTYLE ALL;

CREATE TABLE marts.orders (
    order_id INTEGER PRIMARY KEY,
    customer_id INTEGER,
    order_date TIMESTAMP,
    total_amount DECIMAL(10,2),
    status VARCHAR(50),
    created_date TIMESTAMP,
    updated_date TIMESTAMP,
    -- CDC timestamps
    consumed_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    written_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
DISTSTYLE KEY
DISTKEY (customer_id)
SORTKEY (order_date);