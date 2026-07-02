-- ============================================================
-- STEP 8: BUILD THE MARTS LAYER
-- Business-friendly views on top of the dw star schema.
-- No transformation logic here -- just readable, ready-to-use
-- aggregations and joins for reporting/BI tools.
-- ============================================================


-- ============================================================
-- 8.1 Monthly sales summary
-- ============================================================
CREATE VIEW marts.vw_monthly_sales_summary AS
SELECT
    dd.year,
    dd.month_num,
    dd.month_name,
    COUNT(*)                                   AS num_transactions,
    SUM(f.quantity)                             AS total_units_sold,
    SUM(f.gross_amount)                         AS total_gross_revenue,
    SUM(f.discount_amount)                      AS total_discounts,
    SUM(f.tax_amount)                           AS total_tax,
    SUM(f.net_amount)                           AS total_net_revenue,
    ROUND(SUM(f.net_amount) / NULLIF(COUNT(*), 0), 2) AS avg_order_value
FROM dw.fact_sales f
JOIN dw.dim_date dd ON f.date_key = dd.date_key
GROUP BY dd.year, dd.month_num, dd.month_name
ORDER BY dd.year, dd.month_num;


-- ============================================================
-- 8.2 Store performance
-- ============================================================
CREATE VIEW marts.vw_store_performance AS
SELECT
    s.store_id,
    s.store_name,
    s.region,
    s.city,
    s.state,
    s.store_status,
    COUNT(*)                                    AS num_transactions,
    SUM(f.quantity)                             AS total_units_sold,
    SUM(f.net_amount)                           AS total_net_revenue,
    ROUND(SUM(f.net_amount) / NULLIF(COUNT(*), 0), 2) AS avg_order_value
FROM dw.fact_sales f
JOIN dw.dim_store s ON f.store_key = s.store_key
WHERE s.store_key != -1                          -- exclude unknown-store placeholder
GROUP BY s.store_id, s.store_name, s.region, s.city, s.state, s.store_status
ORDER BY total_net_revenue DESC;


-- ============================================================
-- 8.3 Product performance
-- ============================================================
CREATE VIEW marts.vw_product_performance AS
SELECT
    p.product_code,
    p.product_name,
    p.category,
    p.subcategory,
    p.brand,
    p.product_status,
    COUNT(*)                                    AS num_transactions,
    SUM(f.quantity)                             AS total_units_sold,
    SUM(f.net_amount)                           AS total_net_revenue,
    ROUND(AVG(f.net_amount), 2)                 AS avg_transaction_value
FROM dw.fact_sales f
JOIN dw.dim_product p ON f.product_key = p.product_key
WHERE p.product_key != -1                        -- exclude unknown-product placeholder
GROUP BY p.product_code, p.product_name, p.category, p.subcategory, p.brand, p.product_status
ORDER BY total_net_revenue DESC;


-- ============================================================
-- 8.4 Customer summary (GDPR-aware: PII masked for opted-out customers)
-- ============================================================
CREATE VIEW marts.vw_customer_summary AS
SELECT
    c.customer_id,
    c.customer_name,
    CASE WHEN c.gdpr_opt_out THEN 'REDACTED' ELSE c.email END AS email,
    CASE WHEN c.gdpr_opt_out THEN 'REDACTED' ELSE c.phone END AS phone,
    c.city,
    c.state,
    c.loyalty_tier,
    c.status,
    c.gdpr_opt_out,
    COUNT(f.sales_id)                           AS num_transactions,
    COALESCE(SUM(f.net_amount), 0)              AS lifetime_value,
    MAX(dd.full_date)                           AS last_purchase_date
FROM dw.dim_customer c
LEFT JOIN dw.fact_sales f ON c.customer_key = f.customer_key
LEFT JOIN dw.dim_date dd ON f.date_key = dd.date_key
WHERE c.customer_key != -1                       -- exclude unknown-customer placeholder
  AND c.is_current = TRUE                        -- only the current version of each customer
GROUP BY c.customer_id, c.customer_name, c.email, c.phone, c.city, c.state,
         c.loyalty_tier, c.status, c.gdpr_opt_out;


-- ============================================================
-- 8.5 Returns and cancellations analysis
-- ============================================================
CREATE VIEW marts.vw_returns_analysis AS
SELECT
    p.category,
    p.product_name,
    f.order_status,
    f.return_reason,
    COUNT(*)                                    AS num_orders,
    SUM(f.net_amount)                           AS total_value
FROM dw.fact_sales f
JOIN dw.dim_product p ON f.product_key = p.product_key
WHERE f.order_status IN ('RETURNED', 'CANCELLED')
GROUP BY p.category, p.product_name, f.order_status, f.return_reason
ORDER BY num_orders DESC;


-- ============================================================
-- 8.6 Sales channel and payment mode mix
-- ============================================================
CREATE VIEW marts.vw_channel_payment_mix AS
SELECT
    sales_channel,
    payment_mode,
    COUNT(*)                                    AS num_transactions,
    SUM(net_amount)                             AS total_net_revenue,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_all_transactions
FROM dw.fact_sales
GROUP BY sales_channel, payment_mode
ORDER BY num_transactions DESC;


-- ============================================================
-- Verification: run each view and eyeball the results
-- ============================================================
SELECT * FROM marts.vw_monthly_sales_summary LIMIT 12;
SELECT * FROM marts.vw_store_performance LIMIT 10;
SELECT * FROM marts.vw_product_performance LIMIT 10;
SELECT * FROM marts.vw_customer_summary LIMIT 10;
SELECT * FROM marts.vw_returns_analysis LIMIT 10;
SELECT * FROM marts.vw_channel_payment_mix;
