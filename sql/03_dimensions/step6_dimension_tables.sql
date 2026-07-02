-- ============================================================
-- STEP 6: BUILD DIMENSION TABLES
-- dim_customer, dim_product -> SCD Type 2 (track history)
-- dim_store                 -> SCD Type 1 (overwrite, no history)
-- This is the INITIAL historical load: one current-state row
-- per entity. Change-detection logic for repeat runs comes later
-- when we build the daily pipeline.
-- ============================================================


-- ============================================================
-- 6.1 dim_customer (SCD Type 2)
-- ============================================================

CREATE TABLE dw.dim_customer (
    customer_key     SERIAL PRIMARY KEY,   -- surrogate key, used by fact table
    customer_id      TEXT,                 -- natural/business key from source
    customer_name    TEXT,
    dob              DATE,
    gender           TEXT,
    kyc_type         TEXT,
    kyc_number       TEXT,
    onboard_date     DATE,
    status           TEXT,
    loyalty_tier     TEXT,
    city             TEXT,
    state            TEXT,
    country          TEXT,
    email            TEXT,
    phone            TEXT,
    gdpr_opt_out     BOOLEAN,
    valid_from       DATE NOT NULL,
    valid_to         DATE NOT NULL DEFAULT '9999-12-31',
    is_current       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Unknown member -- catches any future fact row with no matching customer
INSERT INTO dw.dim_customer
    (customer_key, customer_id, customer_name, valid_from, valid_to, is_current)
VALUES
    (-1, 'UNKNOWN', 'Unknown Customer', '1900-01-01', '9999-12-31', TRUE);

-- Reset the sequence so real rows start from 1, not colliding with -1
-- (SERIAL ignores explicit -1 insert, so this is just a safety no-op here,
--  included for clarity)

-- Initial load: one row per customer, valid from their onboarding date
INSERT INTO dw.dim_customer
    (customer_id, customer_name, dob, gender, kyc_type, kyc_number,
     onboard_date, status, loyalty_tier, city, state, country,
     email, phone, gdpr_opt_out, valid_from, valid_to, is_current)
SELECT
    customer_id, customer_name, dob, gender, kyc_type, kyc_number,
    onboard_date, status, loyalty_tier, city, state, country,
    email, phone, gdpr_opt_out,
    onboard_date        AS valid_from,     -- valid since they became a customer
    '9999-12-31'         AS valid_to,
    TRUE                 AS is_current
FROM staging.customer;

-- Verify: 5000 real customers + 1 unknown member = 5001
SELECT COUNT(*) FROM dw.dim_customer;


-- ============================================================
-- 6.2 dim_product (SCD Type 2)
-- ============================================================

CREATE TABLE dw.dim_product (
    product_key          SERIAL PRIMARY KEY,
    product_code         TEXT,
    product_name         TEXT,
    category             TEXT,
    subcategory          TEXT,
    brand                TEXT,
    launch_date          DATE,
    mrp                  NUMERIC(10,2),
    tax_pct              NUMERIC(5,2),
    product_status       TEXT,
    last_price_revision  DATE,
    valid_from           DATE NOT NULL,
    valid_to             DATE NOT NULL DEFAULT '9999-12-31',
    is_current           BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO dw.dim_product
    (product_key, product_code, product_name, valid_from, valid_to, is_current)
VALUES
    (-1, 'UNKNOWN', 'Unknown Product', '1900-01-01', '9999-12-31', TRUE);

INSERT INTO dw.dim_product
    (product_code, product_name, category, subcategory, brand,
     launch_date, mrp, tax_pct, product_status, last_price_revision,
     valid_from, valid_to, is_current)
SELECT
    product_code, product_name, category, subcategory, brand,
    launch_date, mrp, tax_pct, product_status, last_price_revision,
    launch_date          AS valid_from,    -- valid since the product launched
    '9999-12-31'          AS valid_to,
    TRUE                  AS is_current
FROM staging.product_master;

-- Verify: 500 real products + 1 unknown member = 501
SELECT COUNT(*) FROM dw.dim_product;


-- ============================================================
-- 6.3 dim_store (SCD Type 1 -- overwrite, no history tracked)
-- ============================================================

CREATE TABLE dw.dim_store (
    store_key         SERIAL PRIMARY KEY,
    store_id          TEXT,
    store_name        TEXT,
    region            TEXT,
    ownership_model   TEXT,
    opening_date      DATE,
    city              TEXT,
    state             TEXT,
    country           TEXT,
    latitude          NUMERIC(9,6),
    longitude         NUMERIC(9,6),
    store_status      TEXT
);

INSERT INTO dw.dim_store (store_key, store_id, store_name)
VALUES (-1, 'UNKNOWN', 'Unknown Store');

INSERT INTO dw.dim_store
    (store_id, store_name, region, ownership_model, opening_date,
     city, state, country, latitude, longitude, store_status)
SELECT
    store_id, store_name, region, ownership_model, opening_date,
    city, state, country, latitude, longitude, store_status
FROM staging.store_information;

-- Verify: 50 real stores + 1 unknown member = 51
SELECT COUNT(*) FROM dw.dim_store;


-- ============================================================
-- Sanity check across all three: natural keys should be unique
-- among CURRENT rows (a customer/product can have multiple
-- historical versions, but only one current version)
-- ============================================================

SELECT customer_id, COUNT(*)
FROM dw.dim_customer
WHERE is_current = TRUE
GROUP BY customer_id
HAVING COUNT(*) > 1;

SELECT product_code, COUNT(*)
FROM dw.dim_product
WHERE is_current = TRUE
GROUP BY product_code
HAVING COUNT(*) > 1;

SELECT store_id, COUNT(*)
FROM dw.dim_store
GROUP BY store_id
HAVING COUNT(*) > 1;
