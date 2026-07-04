-- ============================================================
-- STEP 9b: SCHEMA ADDITIONS
-- 1) Reject tables for store/product (customer/sales already have them)
--    -- needed so row-level validation has somewhere to quarantine
--    bad rows instead of failing the whole batch.
-- 2) etl_batch_log -- queryable audit trail of every pipeline run.
-- ============================================================

CREATE TABLE staging.store_rejects (
    reject_reason   TEXT,
    store_id        TEXT,
    opening_date    TEXT,
    latitude        TEXT,
    longitude       TEXT,
    loaded_at       TIMESTAMP DEFAULT now()
);

CREATE TABLE staging.product_rejects (
    reject_reason        TEXT,
    product_code         TEXT,
    product_sk            TEXT,
    launch_date          TEXT,
    last_price_revision  TEXT,
    mrp                  TEXT,
    tax_pct              TEXT,
    loaded_at            TIMESTAMP DEFAULT now()
);

CREATE TABLE raw.etl_batch_log (
    batch_id                SERIAL PRIMARY KEY,
    batch_date               DATE NOT NULL,
    started_at               TIMESTAMP NOT NULL DEFAULT now(),
    finished_at              TIMESTAMP,
    status                   TEXT NOT NULL DEFAULT 'RUNNING',   -- RUNNING | SUCCESS | FAILED
    store_rows_upserted      INTEGER,
    product_rows_upserted    INTEGER,
    customer_rows_upserted   INTEGER,
    sales_rows_appended      INTEGER,
    dim_customer_closed      INTEGER,
    dim_customer_inserted    INTEGER,
    dim_product_closed       INTEGER,
    dim_product_inserted     INTEGER,
    fact_rows_appended       INTEGER,
    error_message            TEXT
);

-- Handy view: latest status per batch date at a glance
CREATE VIEW raw.vw_etl_batch_status AS
SELECT batch_date, status, started_at, finished_at,
       (finished_at - started_at) AS duration,
       sales_rows_appended, fact_rows_appended, error_message
FROM raw.etl_batch_log
ORDER BY batch_date DESC, started_at DESC;

-- Broaden the existing sales rejects table to capture whichever field(s)
-- actually caused the row to fail validation, not just tax/net amount
ALTER TABLE staging.sales_transaction_rejects ADD COLUMN sales_id_raw TEXT;
ALTER TABLE staging.sales_transaction_rejects ADD COLUMN quantity_raw TEXT;
ALTER TABLE staging.sales_transaction_rejects ADD COLUMN gross_amount_raw TEXT;
ALTER TABLE staging.sales_transaction_rejects ADD COLUMN discount_amount_raw TEXT;
ALTER TABLE staging.sales_transaction_rejects ADD COLUMN transaction_ts_raw TEXT;
