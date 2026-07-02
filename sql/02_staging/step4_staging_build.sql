-- ============================================================
-- STEP 4: BUILD THE STAGING LAYER
-- Converts raw TEXT data into clean, properly-typed tables.
-- Every fix here is based on confirmed Step 3 profiling results.
-- ============================================================


-- ============================================================
-- 4.1 STAGING TABLE: store_information
-- No cleansing needed (Step 3 confirmed: no blanks, no dupes,
-- dates already YYYY-MM-DD, categories consistent).
-- Just cast to proper types.
-- ============================================================

CREATE TABLE staging.store_information (
    store_id            TEXT PRIMARY KEY,
    store_name          TEXT,
    region              TEXT,
    ownership_model     TEXT,
    opening_date        DATE,
    city                TEXT,
    state               TEXT,
    country             TEXT,
    latitude            NUMERIC(9,6),
    longitude           NUMERIC(9,6),
    store_status        TEXT
);

INSERT INTO staging.store_information
SELECT
    store_id,
    store_name,
    region,
    ownership_model,
    opening_date::DATE,
    city,
    state,
    country,
    latitude::NUMERIC(9,6),
    longitude::NUMERIC(9,6),
    store_status
FROM raw.store_information;


-- ============================================================
-- 4.2 STAGING TABLE: product_master
-- No cleansing needed (Step 3 confirmed: clean across the board).
-- Just cast to proper types.
-- ============================================================

CREATE TABLE staging.product_master (
    product_sk           INTEGER,
    product_code         TEXT PRIMARY KEY,
    product_name         TEXT,
    category             TEXT,
    subcategory          TEXT,
    brand                TEXT,
    launch_date          DATE,
    mrp                  NUMERIC(10,2),
    tax_pct              NUMERIC(5,2),
    product_status       TEXT,
    last_price_revision  DATE
);

INSERT INTO staging.product_master
SELECT
    product_sk::INTEGER,
    product_code,
    product_name,
    category,
    subcategory,
    brand,
    launch_date::DATE,
    mrp::NUMERIC(10,2),
    tax_pct::NUMERIC(5,2),
    product_status,
    last_price_revision::DATE
FROM raw.product_master;


-- ============================================================
-- 4.3 STAGING TABLE: customer
-- Fixes applied (based on confirmed Step 3 findings):
--   - dob, onboard_date: parse DD-MM-YYYY -> DATE
--   - phone: strip negative sign (100% of rows affected, uniform)
--   - gdpr_opt_out: Y/N -> BOOLEAN
--   - last_updated_ts: KEPT AS-IS in a raw text column, flagged
--     unreliable. Every row has the identical value "27:44.8" --
--     this is not a real timestamp and must not be used for any
--     downstream logic (e.g. SCD tracking). We are not attempting
--     to reconstruct it since there is no information to recover.
--   - Duplicates: 25 customer_id values appear twice, each also
--     duplicated on kyc_number/email/phone -> genuine duplicate
--     records. We keep the FIRST occurrence (lowest customer_sk)
--     and move the rest to a reject table for review.
-- ============================================================

CREATE TABLE staging.customer (
    customer_sk           INTEGER,
    customer_id           TEXT PRIMARY KEY,
    customer_name         TEXT,
    dob                   DATE,
    gender                TEXT,
    kyc_type              TEXT,
    kyc_number            TEXT,
    onboard_date          DATE,
    status                TEXT,
    loyalty_tier          TEXT,
    city                  TEXT,
    state                 TEXT,
    country               TEXT,
    email                 TEXT,
    phone                 TEXT,             -- kept as TEXT: phone numbers are identifiers, not quantities
    last_updated_ts_raw   TEXT,             -- unreliable, kept only for audit visibility
    gdpr_opt_out          BOOLEAN
);

-- Rejects table: holds the duplicate rows we did NOT load into staging.customer
CREATE TABLE staging.customer_rejects (
    reject_reason  TEXT,
    customer_sk    TEXT,
    customer_id    TEXT,
    customer_name  TEXT,
    kyc_number     TEXT,
    email          TEXT,
    phone          TEXT,
    loaded_at      TIMESTAMP DEFAULT now()
);

-- Identify duplicates: keep the row with the lowest customer_sk per customer_id
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_sk::INT ASC) AS rn
    FROM raw.customer_management_system
)
INSERT INTO staging.customer
SELECT
    customer_sk::INTEGER,
    customer_id,
    customer_name,
    TO_DATE(dob, 'DD-MM-YYYY'),
    gender,
    kyc_type,
    kyc_number,
    TO_DATE(onboard_date, 'DD-MM-YYYY'),
    status,
    loyalty_tier,
    city,
    state,
    country,
    email,
    REPLACE(phone, '-', ''),                -- strip negative sign
    last_updated_ts,                        -- kept raw, do not trust
    CASE
        WHEN gdpr_opt_out = 'Y' THEN TRUE
        WHEN gdpr_opt_out = 'N' THEN FALSE
        ELSE NULL
    END
FROM ranked
WHERE rn = 1;

-- Move the duplicate (2nd+) occurrences into the rejects table for visibility
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_sk::INT ASC) AS rn
    FROM raw.customer_management_system
)
INSERT INTO staging.customer_rejects (reject_reason, customer_sk, customer_id, customer_name, kyc_number, email, phone)
SELECT
    'duplicate_customer_id',
    customer_sk,
    customer_id,
    customer_name,
    kyc_number,
    email,
    phone
FROM ranked
WHERE rn > 1;

-- Verify: should return 0 (no duplicates left in staging)
SELECT customer_id, COUNT(*) FROM staging.customer GROUP BY customer_id HAVING COUNT(*) > 1;

-- Verify: should return 25 (the rows we set aside)
SELECT COUNT(*) FROM staging.customer_rejects WHERE reject_reason = 'duplicate_customer_id';


-- ============================================================
-- 4.4 STAGING TABLE: sales_transaction
-- Fixes applied:
--   - transaction_ts: already consistent FULL_TIMESTAMP -> cast directly
--   - quantity, gross_amount, discount_amount: already clean -> cast directly
--   - tax_amount, net_amount: 522 rows are malformed (confirmed in
--     Step 3). THESE ARE ROUTED TO A REJECTS TABLE below, pending
--     the investigation query -- do NOT run the final INSERT for
--     this table until we've confirmed what the bad values look like.
--   - return_reason inconsistency (populated on DELIVERED orders,
--     missing on some RETURNED/CANCELLED): we do NOT alter the raw
--     value (no nulling, no guessing a reason). Instead we add a
--     return_reason_dq_flag column that marks rows as
--     'INCONSISTENT' when order_status/return_reason don't line up
--     as expected. The original value is preserved untouched so
--     downstream marts/analysts can decide how to treat it, and we
--     never lose the ability to trace back to what the source said.
-- ============================================================

CREATE TABLE staging.sales_transaction (
    sales_id               BIGINT PRIMARY KEY,
    order_id               TEXT,
    transaction_ts         TIMESTAMP,
    sales_channel          TEXT,
    customer_id            TEXT,
    product_code           TEXT,
    store_id               TEXT,
    quantity               INTEGER,
    gross_amount           NUMERIC(12,2),
    discount_amount        NUMERIC(12,2),
    tax_amount             NUMERIC(12,2),
    net_amount             NUMERIC(12,2),
    payment_mode           TEXT,
    order_status           TEXT,
    return_reason          TEXT,
    return_reason_dq_flag  TEXT       -- 'OK' or 'INCONSISTENT', see logic below
);

CREATE TABLE staging.sales_transaction_rejects (
    reject_reason     TEXT,
    sales_id          TEXT,
    tax_amount_raw    TEXT,
    net_amount_raw    TEXT,
    loaded_at         TIMESTAMP DEFAULT now()
);

-- Load the clean rows only (tax_amount / net_amount pass the numeric check)
INSERT INTO staging.sales_transaction
SELECT
    sales_id::BIGINT,
    order_id,
    transaction_ts::TIMESTAMP,
    sales_channel,
    customer_id,
    product_code,
    store_id,
    quantity::INTEGER,
    gross_amount::NUMERIC(12,2),
    discount_amount::NUMERIC(12,2),
    tax_amount::NUMERIC(12,2),
    net_amount::NUMERIC(12,2),
    payment_mode,
    order_status,
    return_reason,
    CASE
        WHEN order_status = 'DELIVERED' AND return_reason IS NOT NULL AND return_reason != ''
            THEN 'INCONSISTENT'   -- delivered orders shouldn't have a return reason
        WHEN order_status IN ('RETURNED', 'CANCELLED') AND (return_reason IS NULL OR return_reason = '')
            THEN 'INCONSISTENT'   -- returns/cancellations should have a reason but don't
        ELSE 'OK'
    END
FROM raw.sales_transaction
WHERE tax_amount ~ '^\d+(\.\d+)?$'
  AND net_amount ~ '^\d+(\.\d+)?$';

-- Quarantine the 522 problem rows for review
INSERT INTO staging.sales_transaction_rejects (reject_reason, sales_id, tax_amount_raw, net_amount_raw)
SELECT
    'invalid_tax_or_net_amount',
    sales_id,
    tax_amount,
    net_amount
FROM raw.sales_transaction
WHERE tax_amount !~ '^\d+(\.\d+)?$'
   OR net_amount !~ '^\d+(\.\d+)?$';

-- Verify counts: should be 99,478 in staging + 522 in rejects = 100,000
SELECT COUNT(*) FROM staging.sales_transaction;
SELECT COUNT(*) FROM staging.sales_transaction_rejects;

-- Verify the dq flag: see how many rows were flagged INCONSISTENT
SELECT return_reason_dq_flag, COUNT(*) FROM staging.sales_transaction GROUP BY return_reason_dq_flag;
