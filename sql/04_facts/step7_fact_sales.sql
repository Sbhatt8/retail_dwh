-- ============================================================
-- STEP 7: BUILD fact_sales
-- Grain: one row per sales transaction line (same grain as
-- staging.sales_transaction).
-- Translates natural keys -> surrogate keys from the dimensions
-- built in Step 6, and attaches the date_key from dim_date.
-- ============================================================

CREATE TABLE dw.fact_sales (
    sales_id                BIGINT PRIMARY KEY,   -- natural key, already confirmed unique
    order_id                TEXT,
    date_key                INTEGER NOT NULL REFERENCES dw.dim_date(date_key),
    customer_key            INTEGER NOT NULL REFERENCES dw.dim_customer(customer_key),
    product_key             INTEGER NOT NULL REFERENCES dw.dim_product(product_key),
    store_key               INTEGER NOT NULL REFERENCES dw.dim_store(store_key),
    sales_channel           TEXT,                 -- degenerate dimension
    quantity                INTEGER,
    gross_amount            NUMERIC(12,2),
    discount_amount         NUMERIC(12,2),
    tax_amount               NUMERIC(12,2),
    net_amount               NUMERIC(12,2),
    payment_mode            TEXT,                 -- degenerate dimension
    order_status            TEXT,                 -- degenerate dimension
    return_reason           TEXT,
    return_reason_dq_flag   TEXT
);

INSERT INTO dw.fact_sales
SELECT
    s.sales_id,
    s.order_id,
    dd.date_key,
    COALESCE(c.customer_key, -1)   AS customer_key,
    COALESCE(p.product_key, -1)    AS product_key,
    COALESCE(st.store_key, -1)     AS store_key,
    s.sales_channel,
    s.quantity,
    s.gross_amount,
    s.discount_amount,
    s.tax_amount,
    s.net_amount,
    s.payment_mode,
    s.order_status,
    s.return_reason,
    s.return_reason_dq_flag
FROM staging.sales_transaction s
JOIN dw.dim_date dd
    ON s.transaction_ts::DATE = dd.full_date
LEFT JOIN dw.dim_customer c
    ON s.customer_id = c.customer_id
   AND s.transaction_ts::DATE BETWEEN c.valid_from AND c.valid_to
LEFT JOIN dw.dim_product p
    ON s.product_code = p.product_code
   AND s.transaction_ts::DATE BETWEEN p.valid_from AND p.valid_to
LEFT JOIN dw.dim_store st
    ON s.store_id = st.store_id;

-- ============================================================
-- Verification
-- ============================================================

-- Should match staging.sales_transaction row count: 99,478
SELECT COUNT(*) FROM dw.fact_sales;

-- Should be 0 -- confirms every row found a real dimension match
-- (not the -1 unknown fallback)
SELECT
    COUNT(*) FILTER (WHERE customer_key = -1) AS unknown_customers,
    COUNT(*) FILTER (WHERE product_key = -1)  AS unknown_products,
    COUNT(*) FILTER (WHERE store_key = -1)    AS unknown_stores
FROM dw.fact_sales;

-- Sanity: total net_amount in fact should equal total in staging
-- (confirms no double-counting or row loss from the joins)
SELECT
    (SELECT SUM(net_amount) FROM staging.sales_transaction) AS staging_total,
    (SELECT SUM(net_amount) FROM dw.fact_sales)              AS fact_total;

-- Quick end-to-end test: revenue by month (proves the whole star
-- schema actually joins and produces a sensible business answer)
SELECT
    dd.year,
    dd.month_name,
    SUM(f.net_amount) AS total_revenue,
    COUNT(*) AS num_transactions
FROM dw.fact_sales f
JOIN dw.dim_date dd ON f.date_key = dd.date_key
GROUP BY dd.year, dd.month_num, dd.month_name
ORDER BY dd.year, dd.month_num;
