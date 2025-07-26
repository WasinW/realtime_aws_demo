-- Generate 100k test records in Oracle

-- Generate customers
BEGIN
  FOR i IN 1..10000 LOOP
    INSERT INTO cdc_user.customers (first_name, last_name, email, phone)
    VALUES (
      'FirstName' || i,
      'LastName' || i,
      'customer' || i || '@example.com',
      '555-' || LPAD(i, 4, '0')
    );
  END LOOP;
  COMMIT;
END;
/

-- Generate products
BEGIN
  FOR i IN 1..1000 LOOP
    INSERT INTO cdc_user.products (product_name, category, price, stock_quantity)
    VALUES (
      'Product ' || i,
      CASE MOD(i, 5)
        WHEN 0 THEN 'Electronics'
        WHEN 1 THEN 'Clothing'
        WHEN 2 THEN 'Food'
        WHEN 3 THEN 'Books'
        ELSE 'Other'
      END,
      ROUND(DBMS_RANDOM.VALUE(10, 1000), 2),
      ROUND(DBMS_RANDOM.VALUE(0, 1000))
    );
  END LOOP;
  COMMIT;
END;
/

-- Generate orders (90k orders)
BEGIN
  FOR i IN 1..90000 LOOP
    INSERT INTO cdc_user.orders (customer_id, total_amount, status)
    VALUES (
      ROUND(DBMS_RANDOM.VALUE(1, 10000)),
      ROUND(DBMS_RANDOM.VALUE(50, 5000), 2),
      CASE MOD(i, 4)
        WHEN 0 THEN 'COMPLETED'
        WHEN 1 THEN 'PENDING'
        WHEN 2 THEN 'PROCESSING'
        ELSE 'SHIPPED'
      END
    );
    
    -- Commit every 1000 records
    IF MOD(i, 1000) = 0 THEN
      COMMIT;
    END IF;
  END LOOP;
  COMMIT;
END;
/

-- Simulate updates
BEGIN
  -- Update 10% of customers
  UPDATE cdc_user.customers 
  SET phone = '555-' || LPAD(customer_id + 10000, 4, '0')
  WHERE MOD(customer_id, 10) = 0;
  
  -- Update product prices
  UPDATE cdc_user.products
  SET price = price * 1.1
  WHERE MOD(product_id, 5) = 0;
  
  -- Update order status
  UPDATE cdc_user.orders
  SET status = 'COMPLETED'
  WHERE status = 'PROCESSING' 
    AND ROWNUM <= 5000;
  
  COMMIT;
END;
/