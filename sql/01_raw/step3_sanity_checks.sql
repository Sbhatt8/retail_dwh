-- ============================================================
-- STEP 3: DATA PROFILING / SANITY CHECKS
-- Database: suvankar_retail_db | Schema: raw
-- Run each block, note the results, don't fix anything yet.
-- ============================================================


-- ============================================================
-- TABLE 1: raw.store_information
-- ============================================================

-- 1.1 Row count
SELECT COUNT(*) FROM raw.store_information;

-- 1.2 Blank/null check across all columns
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE store_id IS NULL OR store_id = '')         AS blank_store_id,
    COUNT(*) FILTER (WHERE store_name IS NULL OR store_name = '')     AS blank_store_name,
    COUNT(*) FILTER (WHERE region IS NULL OR region = '')             AS blank_region,
    COUNT(*) FILTER (WHERE ownership_model IS NULL OR ownership_model = '') AS blank_ownership_model,
    COUNT(*) FILTER (WHERE opening_date IS NULL OR opening_date = '') AS blank_opening_date,
    COUNT(*) FILTER (WHERE city IS NULL OR city = '')                 AS blank_city,
    COUNT(*) FILTER (WHERE state IS NULL OR state = '')               AS blank_state,
    COUNT(*) FILTER (WHERE country IS NULL OR country = '')           AS blank_country,
    COUNT(*) FILTER (WHERE latitude IS NULL OR latitude = '')         AS blank_latitude,
    COUNT(*) FILTER (WHERE longitude IS NULL OR longitude = '')       AS blank_longitude,
    COUNT(*) FILTER (WHERE store_status IS NULL OR store_status = '') AS blank_store_status
FROM raw.store_information;

-- 1.3 Duplicate store_id check (should be a unique natural key)
SELECT store_id, COUNT(*)
FROM raw.store_information
GROUP BY store_id
HAVING COUNT(*) > 1;

-- 1.4 Distinct values in categorical columns (spot inconsistent labels e.g. "north" vs "North")
SELECT region, COUNT(*) FROM raw.store_information GROUP BY region ORDER BY 2 DESC;
SELECT ownership_model, COUNT(*) FROM raw.store_information GROUP BY ownership_model ORDER BY 2 DESC;
SELECT store_status, COUNT(*) FROM raw.store_information GROUP BY store_status ORDER BY 2 DESC;
SELECT country, COUNT(*) FROM raw.store_information GROUP BY country ORDER BY 2 DESC;

-- 1.5 opening_date format pattern check
SELECT
    CASE
        WHEN opening_date ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
        WHEN opening_date ~ '^\d{2}-\d{2}-\d{4}$' THEN 'DD-MM-YYYY'
        WHEN opening_date ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
        WHEN opening_date IS NULL OR opening_date = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS date_pattern,
    COUNT(*)
FROM raw.store_information
GROUP BY date_pattern
ORDER BY COUNT(*) DESC;

-- 1.6 latitude / longitude sanity range (India: lat ~6 to 38, long ~68 to 98)
SELECT store_id, latitude, longitude
FROM raw.store_information
WHERE latitude !~ '^-?\d+(\.\d+)?$'
   OR longitude !~ '^-?\d+(\.\d+)?$'
   OR latitude::NUMERIC NOT BETWEEN 6 AND 38
   OR longitude::NUMERIC NOT BETWEEN 68 AND 98;

-- 1.7 opening_date not in the future
SELECT store_id, opening_date
FROM raw.store_information
WHERE opening_date::DATE > CURRENT_DATE;   -- will error if format isn't uniform yet; run AFTER 1.5 confirms format


-- ============================================================
-- TABLE 2: raw.product_master
-- ============================================================

-- 2.1 Row count
SELECT COUNT(*) FROM raw.product_master;

-- 2.2 Blank/null check
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE product_sk IS NULL OR product_sk = '')     AS blank_product_sk,
    COUNT(*) FILTER (WHERE product_code IS NULL OR product_code = '') AS blank_product_code,
    COUNT(*) FILTER (WHERE product_name IS NULL OR product_name = '') AS blank_product_name,
    COUNT(*) FILTER (WHERE category IS NULL OR category = '')         AS blank_category,
    COUNT(*) FILTER (WHERE subcategory IS NULL OR subcategory = '')   AS blank_subcategory,
    COUNT(*) FILTER (WHERE brand IS NULL OR brand = '')               AS blank_brand,
    COUNT(*) FILTER (WHERE launch_date IS NULL OR launch_date = '')   AS blank_launch_date,
    COUNT(*) FILTER (WHERE mrp IS NULL OR mrp = '')                   AS blank_mrp,
    COUNT(*) FILTER (WHERE tax_pct IS NULL OR tax_pct = '')           AS blank_tax_pct,
    COUNT(*) FILTER (WHERE product_status IS NULL OR product_status = '') AS blank_product_status,
    COUNT(*) FILTER (WHERE last_price_revision IS NULL OR last_price_revision = '') AS blank_last_price_revision
FROM raw.product_master;

-- 2.3 Duplicate product_code check
SELECT product_code, COUNT(*)
FROM raw.product_master
GROUP BY product_code
HAVING COUNT(*) > 1;

-- 2.4 Distinct categorical values
SELECT category, COUNT(*) FROM raw.product_master GROUP BY category ORDER BY 2 DESC;
SELECT subcategory, COUNT(*) FROM raw.product_master GROUP BY subcategory ORDER BY 2 DESC;
SELECT brand, COUNT(*) FROM raw.product_master GROUP BY brand ORDER BY 2 DESC;
SELECT product_status, COUNT(*) FROM raw.product_master GROUP BY product_status ORDER BY 2 DESC;

-- 2.5 mrp / tax_pct numeric validity + range sanity
SELECT product_code, mrp
FROM raw.product_master
WHERE mrp !~ '^\d+(\.\d+)?$' OR mrp::NUMERIC <= 0;

SELECT product_code, tax_pct
FROM raw.product_master
WHERE tax_pct !~ '^\d+(\.\d+)?$' OR tax_pct::NUMERIC NOT BETWEEN 0 AND 50;  -- adjust upper bound to your known tax slabs

-- 2.6 launch_date / last_price_revision format pattern check
SELECT
    CASE
        WHEN launch_date ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
        WHEN launch_date ~ '^\d{2}-\d{2}-\d{4}$' THEN 'DD-MM-YYYY'
        WHEN launch_date ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
        WHEN launch_date IS NULL OR launch_date = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS date_pattern, COUNT(*)
FROM raw.product_master GROUP BY date_pattern ORDER BY COUNT(*) DESC;

SELECT
    CASE
        WHEN last_price_revision ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
        WHEN last_price_revision ~ '^\d{2}-\d{2}-\d{4}$' THEN 'DD-MM-YYYY'
        WHEN last_price_revision ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
        WHEN last_price_revision IS NULL OR last_price_revision = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS date_pattern, COUNT(*)
FROM raw.product_master GROUP BY date_pattern ORDER BY COUNT(*) DESC;

-- 2.7 Cross-field logic check: last_price_revision should not be before launch_date
-- (run once both columns are confirmed to be in a single consistent format)
-- SELECT product_code, launch_date, last_price_revision
-- FROM raw.product_master
-- WHERE last_price_revision::DATE < launch_date::DATE;


-- ============================================================
-- TABLE 3: raw.customer_management_system
-- ============================================================

-- 3.1 Row count
SELECT COUNT(*) FROM raw.customer_management_system;

-- 3.2 Blank/null check
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE customer_sk IS NULL OR customer_sk = '')   AS blank_customer_sk,
    COUNT(*) FILTER (WHERE customer_id IS NULL OR customer_id = '')   AS blank_customer_id,
    COUNT(*) FILTER (WHERE customer_name IS NULL OR customer_name = '') AS blank_customer_name,
    COUNT(*) FILTER (WHERE dob IS NULL OR dob = '')                   AS blank_dob,
    COUNT(*) FILTER (WHERE gender IS NULL OR gender = '')             AS blank_gender,
    COUNT(*) FILTER (WHERE kyc_type IS NULL OR kyc_type = '')         AS blank_kyc_type,
    COUNT(*) FILTER (WHERE kyc_number IS NULL OR kyc_number = '')     AS blank_kyc_number,
    COUNT(*) FILTER (WHERE onboard_date IS NULL OR onboard_date = '') AS blank_onboard_date,
    COUNT(*) FILTER (WHERE status IS NULL OR status = '')             AS blank_status,
    COUNT(*) FILTER (WHERE loyalty_tier IS NULL OR loyalty_tier = '') AS blank_loyalty_tier,
    COUNT(*) FILTER (WHERE city IS NULL OR city = '')                 AS blank_city,
    COUNT(*) FILTER (WHERE state IS NULL OR state = '')               AS blank_state,
    COUNT(*) FILTER (WHERE country IS NULL OR country = '')           AS blank_country,
    COUNT(*) FILTER (WHERE email IS NULL OR email = '')               AS blank_email,
    COUNT(*) FILTER (WHERE phone IS NULL OR phone = '')               AS blank_phone,
    COUNT(*) FILTER (WHERE last_updated_ts IS NULL OR last_updated_ts = '') AS blank_last_updated_ts,
    COUNT(*) FILTER (WHERE gdpr_opt_out IS NULL OR gdpr_opt_out = '') AS blank_gdpr_opt_out
FROM raw.customer_management_system;

-- 3.3 Duplicate customer_id / customer_sk check
SELECT customer_id, COUNT(*) FROM raw.customer_management_system GROUP BY customer_id HAVING COUNT(*) > 1;
SELECT customer_sk, COUNT(*) FROM raw.customer_management_system GROUP BY customer_sk HAVING COUNT(*) > 1;

-- 3.4 Duplicate KYC number check (same KYC used by multiple customer records = possible dupe identity)
SELECT kyc_number, COUNT(*)
FROM raw.customer_management_system
WHERE kyc_number IS NOT NULL AND kyc_number != ''
GROUP BY kyc_number
HAVING COUNT(*) > 1;

-- 3.5 dob format pattern check
SELECT
    CASE
        WHEN dob ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
        WHEN dob ~ '^\d{2}-\d{2}-\d{4}$' THEN 'DD-MM-YYYY'
        WHEN dob ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
        WHEN dob IS NULL OR dob = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS date_pattern, COUNT(*)
FROM raw.customer_management_system GROUP BY date_pattern ORDER BY COUNT(*) DESC;

-- 3.6 onboard_date format pattern check
SELECT
    CASE
        WHEN onboard_date ~ '^\d{4}-\d{2}-\d{2}$' THEN 'YYYY-MM-DD'
        WHEN onboard_date ~ '^\d{2}-\d{2}-\d{4}$' THEN 'DD-MM-YYYY'
        WHEN onboard_date ~ '^\d{2}/\d{2}/\d{4}$' THEN 'DD/MM/YYYY'
        WHEN onboard_date IS NULL OR onboard_date = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS date_pattern, COUNT(*)
FROM raw.customer_management_system GROUP BY date_pattern ORDER BY COUNT(*) DESC;

-- 3.7 last_updated_ts pattern check (this is the suspected malformed column)
SELECT
    CASE
        WHEN last_updated_ts ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}' THEN 'FULL_TIMESTAMP'
        WHEN last_updated_ts ~ '^\d{2}:\d{2}(\.\d+)?$' THEN 'TIME_ONLY_TRUNCATED'
        WHEN last_updated_ts IS NULL OR last_updated_ts = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS ts_pattern, COUNT(*)
FROM raw.customer_management_system GROUP BY ts_pattern ORDER BY COUNT(*) DESC;

-- see actual sample values behind each unknown pattern
SELECT last_updated_ts, COUNT(*)
FROM raw.customer_management_system
WHERE last_updated_ts !~ '^\d{4}-\d{2}-\d{2}'
GROUP BY last_updated_ts
ORDER BY COUNT(*) DESC
LIMIT 30;

-- 3.8 dob plausibility (future dates, or implausibly old customers e.g. > 100 years)
-- run AFTER date format is confirmed and cast correctly
-- SELECT customer_id, dob FROM raw.customer_management_system
-- WHERE dob::DATE > CURRENT_DATE OR dob::DATE < CURRENT_DATE - INTERVAL '100 years';

-- 3.9 phone number checks
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE phone ~ '^-')                              AS negative_phones,
    COUNT(*) FILTER (WHERE phone !~ '^-?\d+$')                        AS non_numeric_phones,
    COUNT(*) FILTER (WHERE LENGTH(REPLACE(phone,'-','')) != 10)       AS wrong_length_phones
FROM raw.customer_management_system;

-- sample the negative ones directly
SELECT customer_id, phone FROM raw.customer_management_system WHERE phone ~ '^-' LIMIT 20;

-- duplicate phone numbers (possible same person registered twice)
SELECT phone, COUNT(*) FROM raw.customer_management_system
GROUP BY phone HAVING COUNT(*) > 1;

-- 3.10 email format validity
SELECT customer_id, email
FROM raw.customer_management_system
WHERE email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  AND email IS NOT NULL AND email != '';

-- duplicate emails
SELECT email, COUNT(*) FROM raw.customer_management_system
WHERE email IS NOT NULL AND email != ''
GROUP BY email HAVING COUNT(*) > 1;

-- 3.11 Distinct categorical values (spot inconsistent casing / stray values)
SELECT gender, COUNT(*) FROM raw.customer_management_system GROUP BY gender ORDER BY 2 DESC;
SELECT kyc_type, COUNT(*) FROM raw.customer_management_system GROUP BY kyc_type ORDER BY 2 DESC;
SELECT status, COUNT(*) FROM raw.customer_management_system GROUP BY status ORDER BY 2 DESC;
SELECT loyalty_tier, COUNT(*) FROM raw.customer_management_system GROUP BY loyalty_tier ORDER BY 2 DESC;
SELECT gdpr_opt_out, COUNT(*) FROM raw.customer_management_system GROUP BY gdpr_opt_out ORDER BY 2 DESC;
SELECT country, COUNT(*) FROM raw.customer_management_system GROUP BY country ORDER BY 2 DESC;

-- 3.12 kyc_number format consistency by kyc_type (e.g. PAN vs Aadhaar have different lengths/patterns)
SELECT kyc_type, LENGTH(kyc_number) AS kyc_len, COUNT(*)
FROM raw.customer_management_system
WHERE kyc_number IS NOT NULL AND kyc_number != ''
GROUP BY kyc_type, kyc_len
ORDER BY kyc_type, kyc_len;


-- ============================================================
-- TABLE 4: raw.sales_transaction
-- ============================================================

-- 4.1 Row count
SELECT COUNT(*) FROM raw.sales_transaction;

-- 4.2 Blank/null check
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE sales_id IS NULL OR sales_id = '')             AS blank_sales_id,
    COUNT(*) FILTER (WHERE order_id IS NULL OR order_id = '')             AS blank_order_id,
    COUNT(*) FILTER (WHERE transaction_ts IS NULL OR transaction_ts = '') AS blank_transaction_ts,
    COUNT(*) FILTER (WHERE sales_channel IS NULL OR sales_channel = '')   AS blank_sales_channel,
    COUNT(*) FILTER (WHERE customer_id IS NULL OR customer_id = '')       AS blank_customer_id,
    COUNT(*) FILTER (WHERE product_code IS NULL OR product_code = '')     AS blank_product_code,
    COUNT(*) FILTER (WHERE store_id IS NULL OR store_id = '')             AS blank_store_id,
    COUNT(*) FILTER (WHERE quantity IS NULL OR quantity = '')             AS blank_quantity,
    COUNT(*) FILTER (WHERE gross_amount IS NULL OR gross_amount = '')     AS blank_gross_amount,
    COUNT(*) FILTER (WHERE discount_amount IS NULL OR discount_amount = '') AS blank_discount_amount,
    COUNT(*) FILTER (WHERE tax_amount IS NULL OR tax_amount = '')         AS blank_tax_amount,
    COUNT(*) FILTER (WHERE net_amount IS NULL OR net_amount = '')         AS blank_net_amount,
    COUNT(*) FILTER (WHERE payment_mode IS NULL OR payment_mode = '')     AS blank_payment_mode,
    COUNT(*) FILTER (WHERE order_status IS NULL OR order_status = '')     AS blank_order_status,
    COUNT(*) FILTER (WHERE return_reason IS NULL OR return_reason = '')   AS blank_return_reason
FROM raw.sales_transaction;

-- 4.3 Duplicate sales_id check (should be unique primary key of the fact)
SELECT sales_id, COUNT(*) FROM raw.sales_transaction GROUP BY sales_id HAVING COUNT(*) > 1;

-- 4.4 transaction_ts format pattern check
SELECT
    CASE
        WHEN transaction_ts ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}' THEN 'FULL_TIMESTAMP'
        WHEN transaction_ts ~ '^\d{4}-\d{2}-\d{2}$' THEN 'DATE_ONLY'
        WHEN transaction_ts ~ '^\d{2}-\d{2}-\d{4}' THEN 'DD-MM-YYYY_VARIANT'
        WHEN transaction_ts IS NULL OR transaction_ts = '' THEN 'BLANK'
        ELSE 'OTHER/UNKNOWN'
    END AS ts_pattern, COUNT(*)
FROM raw.sales_transaction GROUP BY ts_pattern ORDER BY COUNT(*) DESC;

-- 4.5 quantity / amount numeric validity and range sanity
SELECT COUNT(*) FILTER (WHERE quantity !~ '^\d+$' OR quantity::INT <= 0) AS bad_quantity FROM raw.sales_transaction;
SELECT COUNT(*) FILTER (WHERE gross_amount !~ '^\d+(\.\d+)?$' OR gross_amount::NUMERIC < 0) AS bad_gross_amount FROM raw.sales_transaction;
SELECT COUNT(*) FILTER (WHERE discount_amount !~ '^\d+(\.\d+)?$' OR discount_amount::NUMERIC < 0) AS bad_discount FROM raw.sales_transaction;
SELECT COUNT(*) FILTER (WHERE tax_amount !~ '^\d+(\.\d+)?$' OR tax_amount::NUMERIC < 0) AS bad_tax FROM raw.sales_transaction;
SELECT COUNT(*) FILTER (WHERE net_amount !~ '^\d+(\.\d+)?$' OR net_amount::NUMERIC < 0) AS bad_net_amount FROM raw.sales_transaction;

-- 4.6 Cross-field consistency: does net_amount = gross_amount - discount_amount + tax_amount?
-- (run once all 4 amount columns are confirmed numeric-clean)
SELECT sales_id, gross_amount, discount_amount, tax_amount, net_amount,
       (gross_amount::NUMERIC - discount_amount::NUMERIC + tax_amount::NUMERIC) AS calculated_net
FROM raw.sales_transaction
WHERE gross_amount ~ '^\d+(\.\d+)?$' AND discount_amount ~ '^\d+(\.\d+)?$'
  AND tax_amount ~ '^\d+(\.\d+)?$' AND net_amount ~ '^\d+(\.\d+)?$'
  AND ABS((gross_amount::NUMERIC - discount_amount::NUMERIC + tax_amount::NUMERIC) - net_amount::NUMERIC) > 1
LIMIT 50;

-- 4.7 Distinct categorical values
SELECT sales_channel, COUNT(*) FROM raw.sales_transaction GROUP BY sales_channel ORDER BY 2 DESC;
SELECT payment_mode, COUNT(*) FROM raw.sales_transaction GROUP BY payment_mode ORDER BY 2 DESC;
SELECT order_status, COUNT(*) FROM raw.sales_transaction GROUP BY order_status ORDER BY 2 DESC;
SELECT return_reason, COUNT(*) FROM raw.sales_transaction GROUP BY return_reason ORDER BY 2 DESC;

-- 4.8 return_reason should only be populated when order_status indicates a return
SELECT order_status, COUNT(*) FILTER (WHERE return_reason IS NOT NULL AND return_reason != '') AS has_reason,
       COUNT(*) FILTER (WHERE return_reason IS NULL OR return_reason = '') AS no_reason
FROM raw.sales_transaction
GROUP BY order_status;

-- 4.9 REFERENTIAL INTEGRITY: orphan sales rows (fact pointing to a dimension row that doesn't exist)
SELECT COUNT(*) AS orphan_customers
FROM raw.sales_transaction s
LEFT JOIN raw.customer_management_system c ON s.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

SELECT COUNT(*) AS orphan_products
FROM raw.sales_transaction s
LEFT JOIN raw.product_master p ON s.product_code = p.product_code
WHERE p.product_code IS NULL;

SELECT COUNT(*) AS orphan_stores
FROM raw.sales_transaction s
LEFT JOIN raw.store_information st ON s.store_id = st.store_id
WHERE st.store_id IS NULL;

-- 4.10 transaction_ts should not be before the store's opening_date, or in the future
-- (run once transaction_ts and opening_date are both confirmed/cast to DATE)
-- SELECT s.sales_id, s.transaction_ts, st.opening_date
-- FROM raw.sales_transaction s
-- JOIN raw.store_information st ON s.store_id = st.store_id
-- WHERE s.transaction_ts::DATE < st.opening_date::DATE OR s.transaction_ts::DATE > CURRENT_DATE;

-- 4.11 duplicate order_id + product_code combination check (same line item entered twice)
SELECT order_id, product_code, COUNT(*)
FROM raw.sales_transaction
GROUP BY order_id, product_code
HAVING COUNT(*) > 1;


-- ============================================================
-- SUMMARY: row counts across all 4 tables (quick sanity check)
-- ============================================================
SELECT 'store_information' AS tbl, COUNT(*) FROM raw.store_information
UNION ALL
SELECT 'product_master', COUNT(*) FROM raw.product_master
UNION ALL
SELECT 'customer_management_system', COUNT(*) FROM raw.customer_management_system
UNION ALL
SELECT 'sales_transaction', COUNT(*) FROM raw.sales_transaction;
