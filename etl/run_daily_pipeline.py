"""
run_daily_pipeline.py

Scans data/incoming/ for date-named batch folders not yet fully processed,
validates each CSV, loads it into raw (append, tagged with batch_date),
then upserts staging, merges SCD2 changes into dw dimensions, and appends
new fact rows. Each batch is processed in its own transaction: either the
whole batch succeeds, or nothing about it is committed.

Run manually with:  python etl/run_daily_pipeline.py
Schedule with cron / Task Scheduler once you're happy with manual runs.
"""

import os
import io
import shutil
import logging
from datetime import datetime, date, timedelta

import pandas as pd
import psycopg2
from dotenv import load_dotenv

# ============================================================
# SETUP
# ============================================================

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.FileHandler("etl/pipeline.log"),
        logging.StreamHandler()
    ]
)
log = logging.getLogger(__name__)

BASE_DIR = os.getenv("DATA_DIR", "data")
INCOMING_DIR = os.path.join(BASE_DIR, "incoming")
PROCESSED_DIR = os.path.join(BASE_DIR, "processed")
JUNK_DIR = os.path.join(BASE_DIR, "junk")

# expected column order for each source file -> (raw table, columns)
FILE_SPECS = {
    "store_information.csv": (
        "raw.store_information",
        ["store_id", "store_name", "region", "ownership_model", "opening_date",
         "city", "state", "country", "latitude", "longitude", "store_status"]
    ),
    "product_master.csv": (
        "raw.product_master",
        ["product_sk", "product_code", "product_name", "category", "subcategory",
         "brand", "launch_date", "mrp", "tax_pct", "product_status", "last_price_revision"]
    ),
    "customer_management_system.csv": (
        "raw.customer_management_system",
        ["customer_sk", "customer_id", "customer_name", "dob", "gender", "kyc_type",
         "kyc_number", "onboard_date", "status", "loyalty_tier", "city", "state",
         "country", "email", "phone", "last_updated_ts", "gdpr_opt_out"]
    ),
    "sales_transaction.csv": (
        "raw.sales_transaction",
        ["sales_id", "order_id", "transaction_ts", "sales_channel", "customer_id",
         "product_code", "store_id", "quantity", "gross_amount", "discount_amount",
         "tax_amount", "net_amount", "payment_mode", "order_status", "return_reason"]
    ),
}


def get_connection():
    conn = psycopg2.connect(
        host=os.getenv("DB_HOST"),
        port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD")
    )
    conn.autocommit = False   # we control commits per batch
    return conn


# ============================================================
# AUDIT LOGGING
# Uses its OWN connection with autocommit=True so a log entry
# is preserved even if the main batch transaction later rolls
# back. Without this, a FAILED batch would leave no trace in
# etl_batch_log -- exactly the case you most want visibility into.
# ============================================================

def log_batch_start(batch_date_str):
    conn = psycopg2.connect(
        host=os.getenv("DB_HOST"), port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD")
    )
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO raw.etl_batch_log (batch_date, status) VALUES (%s, 'RUNNING') RETURNING batch_id;",
        (batch_date_str,)
    )
    batch_id = cur.fetchone()[0]
    cur.close()
    conn.close()
    return batch_id


def log_batch_end(batch_id, status, counts=None, error_message=None):
    counts = counts or {}
    conn = psycopg2.connect(
        host=os.getenv("DB_HOST"), port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"), user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD")
    )
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("""
        UPDATE raw.etl_batch_log SET
            finished_at = now(),
            status = %s,
            store_rows_upserted = %s,
            product_rows_upserted = %s,
            customer_rows_upserted = %s,
            sales_rows_appended = %s,
            dim_customer_closed = %s,
            dim_customer_inserted = %s,
            dim_product_closed = %s,
            dim_product_inserted = %s,
            fact_rows_appended = %s,
            error_message = %s
        WHERE batch_id = %s;
    """, (
        status,
        counts.get("store_rows"), counts.get("product_rows"),
        counts.get("customer_rows"), counts.get("sales_rows"),
        counts.get("dim_customer_closed"), counts.get("dim_customer_inserted"),
        counts.get("dim_product_closed"), counts.get("dim_product_inserted"),
        counts.get("fact_rows"),
        error_message, batch_id
    ))
    cur.close()
    conn.close()


# ============================================================
# STEP 1: FIND PENDING BATCHES
# ============================================================

def get_pending_batches():
    """Any date-folder under incoming/ that still has at least one file."""
    if not os.path.isdir(INCOMING_DIR):
        return []
    pending = []
    for name in sorted(os.listdir(INCOMING_DIR)):
        folder = os.path.join(INCOMING_DIR, name)
        if os.path.isdir(folder) and any(f.endswith(".csv") for f in os.listdir(folder)):
            pending.append(name)
    return pending


# ============================================================
# STEP 2: VALIDATE + LOAD RAW (append, tagged with batch_date)
# ============================================================

def validate_file(filepath, expected_columns):
    try:
        df = pd.read_csv(filepath, dtype=str, keep_default_na=False, nrows=5)
    except Exception as e:
        return False, f"unreadable file: {e}"

    if set(df.columns) != set(expected_columns):
        missing = set(expected_columns) - set(df.columns)
        extra = set(df.columns) - set(expected_columns)
        return False, f"column mismatch (missing={missing}, extra={extra})"

    return True, "ok"


def load_raw(conn, filepath, table_name, columns, batch_date_str):
    df = pd.read_csv(filepath, dtype=str, keep_default_na=False)
    df = df[columns]  # enforce consistent column order
    df["batch_date"] = batch_date_str

    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False, sep="\t")
    buffer.seek(0)

    cur = conn.cursor()
    cur.copy_expert(
        f"COPY {table_name} ({', '.join(columns)}, batch_date) "
        f"FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t', NULL '')",
        buffer
    )
    cur.close()
    return len(df)


def try_load_raw_file(conn, filepath, table_name, columns, batch_date_str):
    """
    Attempts the raw load inside a SAVEPOINT, so a failure here (bad data
    that slips past structural validation, a type-cast error, etc.) can be
    rolled back in isolation -- without aborting the whole batch's
    transaction or losing progress already made on other files.

    Returns (success: bool, rows_loaded_or_error_message).
    """
    cur = conn.cursor()
    try:
        cur.execute("SAVEPOINT file_load;")
        rows = load_raw(conn, filepath, table_name, columns, batch_date_str)
        cur.execute("RELEASE SAVEPOINT file_load;")
        return True, rows
    except Exception as e:
        cur.execute("ROLLBACK TO SAVEPOINT file_load;")
        return False, str(e)
    finally:
        cur.close()


# ============================================================
# STEP 3: STAGING -- upsert masters, append-only sales
# ============================================================

def upsert_staging_store(conn, batch_date_str):
    cur = conn.cursor()

    # quarantine rows that would fail the type casts below
    cur.execute("""
        INSERT INTO staging.store_rejects (reject_reason, store_id, opening_date, latitude, longitude)
        SELECT 'invalid_date_or_coordinates', store_id, opening_date, latitude, longitude
        FROM raw.store_information
        WHERE batch_date = %s
          AND (
              opening_date !~ '^\\d{4}-\\d{2}-\\d{2}$'
              OR latitude !~ '^-?\\d+(\\.\\d+)?$'
              OR longitude !~ '^-?\\d+(\\.\\d+)?$'
          );
    """, (batch_date_str,))

    cur.execute("""
        INSERT INTO staging.store_information
            (store_id, store_name, region, ownership_model, opening_date,
             city, state, country, latitude, longitude, store_status)
        SELECT
            store_id, store_name, region, ownership_model, opening_date::DATE,
            city, state, country, latitude::NUMERIC(9,6), longitude::NUMERIC(9,6), store_status
        FROM raw.store_information
        WHERE batch_date = %s
          AND opening_date ~ '^\\d{4}-\\d{2}-\\d{2}$'
          AND latitude ~ '^-?\\d+(\\.\\d+)?$'
          AND longitude ~ '^-?\\d+(\\.\\d+)?$'
        ON CONFLICT (store_id) DO UPDATE SET
            store_name = EXCLUDED.store_name,
            region = EXCLUDED.region,
            ownership_model = EXCLUDED.ownership_model,
            opening_date = EXCLUDED.opening_date,
            city = EXCLUDED.city,
            state = EXCLUDED.state,
            country = EXCLUDED.country,
            latitude = EXCLUDED.latitude,
            longitude = EXCLUDED.longitude,
            store_status = EXCLUDED.store_status;
    """, (batch_date_str,))
    count = cur.rowcount
    cur.close()
    return count


def upsert_staging_product(conn, batch_date_str):
    cur = conn.cursor()

    cur.execute("""
        INSERT INTO staging.product_rejects
            (reject_reason, product_code, product_sk, launch_date, last_price_revision, mrp, tax_pct)
        SELECT 'invalid_numeric_or_date', product_code, product_sk, launch_date,
               last_price_revision, mrp, tax_pct
        FROM raw.product_master
        WHERE batch_date = %s
          AND (
              product_sk !~ '^\\d+$'
              OR launch_date !~ '^\\d{4}-\\d{2}-\\d{2}$'
              OR last_price_revision !~ '^\\d{4}-\\d{2}-\\d{2}$'
              OR mrp !~ '^\\d+(\\.\\d+)?$'
              OR tax_pct !~ '^\\d+(\\.\\d+)?$'
          );
    """, (batch_date_str,))

    cur.execute("""
        INSERT INTO staging.product_master
            (product_sk, product_code, product_name, category, subcategory, brand,
             launch_date, mrp, tax_pct, product_status, last_price_revision)
        SELECT
            product_sk::INTEGER, product_code, product_name, category, subcategory, brand,
            launch_date::DATE, mrp::NUMERIC(10,2), tax_pct::NUMERIC(5,2),
            product_status, last_price_revision::DATE
        FROM raw.product_master
        WHERE batch_date = %s
          AND product_sk ~ '^\\d+$'
          AND launch_date ~ '^\\d{4}-\\d{2}-\\d{2}$'
          AND last_price_revision ~ '^\\d{4}-\\d{2}-\\d{2}$'
          AND mrp ~ '^\\d+(\\.\\d+)?$'
          AND tax_pct ~ '^\\d+(\\.\\d+)?$'
        ON CONFLICT (product_code) DO UPDATE SET
            product_sk = EXCLUDED.product_sk,
            product_name = EXCLUDED.product_name,
            category = EXCLUDED.category,
            subcategory = EXCLUDED.subcategory,
            brand = EXCLUDED.brand,
            launch_date = EXCLUDED.launch_date,
            mrp = EXCLUDED.mrp,
            tax_pct = EXCLUDED.tax_pct,
            product_status = EXCLUDED.product_status,
            last_price_revision = EXCLUDED.last_price_revision;
    """, (batch_date_str,))
    count = cur.rowcount
    cur.close()
    return count


def upsert_staging_customer(conn, batch_date_str):
    cur = conn.cursor()

    # quarantine rows with bad dates or a non-numeric customer_sk
    cur.execute("""
        INSERT INTO staging.customer_rejects
            (reject_reason, customer_sk, customer_id, customer_name, kyc_number, email, phone)
        SELECT 'invalid_date_or_sk', customer_sk, customer_id, customer_name, kyc_number, email, phone
        FROM raw.customer_management_system
        WHERE batch_date = %s
          AND (
              customer_sk !~ '^\\d+$'
              OR dob !~ '^\\d{2}-\\d{2}-\\d{4}$'
              OR onboard_date !~ '^\\d{2}-\\d{2}-\\d{4}$'
          );
    """, (batch_date_str,))

    # de-dup within today's incoming batch (keep lowest customer_sk) among
    # the rows that already passed the format check above
    cur.execute("""
        INSERT INTO staging.customer_rejects
            (reject_reason, customer_sk, customer_id, customer_name, kyc_number, email, phone)
        SELECT 'duplicate_customer_id_in_batch', customer_sk, customer_id, customer_name,
               kyc_number, email, phone
        FROM (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_sk::INT) AS rn
            FROM raw.customer_management_system
            WHERE batch_date = %s
              AND customer_sk ~ '^\\d+$'
              AND dob ~ '^\\d{2}-\\d{2}-\\d{4}$'
              AND onboard_date ~ '^\\d{2}-\\d{2}-\\d{4}$'
        ) ranked
        WHERE rn > 1;
    """, (batch_date_str,))

    cur.execute("""
        INSERT INTO staging.customer
            (customer_sk, customer_id, customer_name, dob, gender, kyc_type, kyc_number,
             onboard_date, status, loyalty_tier, city, state, country, email, phone,
             last_updated_ts_raw, gdpr_opt_out)
        SELECT
            customer_sk::INTEGER, customer_id, customer_name,
            TO_DATE(dob, 'DD-MM-YYYY'), gender, kyc_type, kyc_number,
            TO_DATE(onboard_date, 'DD-MM-YYYY'), status, loyalty_tier, city, state, country,
            email, REPLACE(phone, '-', ''), last_updated_ts,
            CASE WHEN gdpr_opt_out = 'Y' THEN TRUE WHEN gdpr_opt_out = 'N' THEN FALSE ELSE NULL END
        FROM (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_sk::INT) AS rn
            FROM raw.customer_management_system
            WHERE batch_date = %s
              AND customer_sk ~ '^\\d+$'
              AND dob ~ '^\\d{2}-\\d{2}-\\d{4}$'
              AND onboard_date ~ '^\\d{2}-\\d{2}-\\d{4}$'
        ) ranked
        WHERE rn = 1
        ON CONFLICT (customer_id) DO UPDATE SET
            customer_sk = EXCLUDED.customer_sk,
            customer_name = EXCLUDED.customer_name,
            dob = EXCLUDED.dob,
            gender = EXCLUDED.gender,
            kyc_type = EXCLUDED.kyc_type,
            kyc_number = EXCLUDED.kyc_number,
            onboard_date = EXCLUDED.onboard_date,
            status = EXCLUDED.status,
            loyalty_tier = EXCLUDED.loyalty_tier,
            city = EXCLUDED.city,
            state = EXCLUDED.state,
            country = EXCLUDED.country,
            email = EXCLUDED.email,
            phone = EXCLUDED.phone,
            last_updated_ts_raw = EXCLUDED.last_updated_ts_raw,
            gdpr_opt_out = EXCLUDED.gdpr_opt_out;
    """, (batch_date_str,))
    count = cur.rowcount
    cur.close()
    return count


def append_staging_sales(conn, batch_date_str):
    cur = conn.cursor()

    # quarantine any row that would fail ANY of the type casts below --
    # previously only tax_amount/net_amount were checked, so a bad
    # quantity or transaction_ts would have thrown mid-INSERT and
    # aborted the whole batch instead of just quarantining that row
    cur.execute("""
        INSERT INTO staging.sales_transaction_rejects
            (reject_reason, sales_id_raw, quantity_raw, gross_amount_raw,
             discount_amount_raw, tax_amount_raw, net_amount_raw, transaction_ts_raw)
        SELECT 'invalid_numeric_or_date_field', sales_id, quantity, gross_amount,
               discount_amount, tax_amount, net_amount, transaction_ts
        FROM raw.sales_transaction
        WHERE batch_date = %s
          AND (
              sales_id !~ '^\\d+$'
              OR quantity !~ '^\\d+$'
              OR gross_amount !~ '^\\d+(\\.\\d+)?$'
              OR discount_amount !~ '^\\d+(\\.\\d+)?$'
              OR tax_amount !~ '^\\d+(\\.\\d+)?$'
              OR net_amount !~ '^\\d+(\\.\\d+)?$'
              OR transaction_ts !~ '^\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}'
          );
    """, (batch_date_str,))

    # append-only: only sales_ids not already in staging, and only rows
    # that passed every format check above
    cur.execute("""
        INSERT INTO staging.sales_transaction
            (sales_id, order_id, transaction_ts, sales_channel, customer_id, product_code,
             store_id, quantity, gross_amount, discount_amount, tax_amount, net_amount,
             payment_mode, order_status, return_reason, return_reason_dq_flag)
        SELECT
            r.sales_id::BIGINT, r.order_id, r.transaction_ts::TIMESTAMP, r.sales_channel,
            r.customer_id, r.product_code, r.store_id, r.quantity::INTEGER,
            r.gross_amount::NUMERIC(12,2), r.discount_amount::NUMERIC(12,2),
            r.tax_amount::NUMERIC(12,2), r.net_amount::NUMERIC(12,2),
            r.payment_mode, r.order_status, r.return_reason,
            CASE
                WHEN r.order_status = 'DELIVERED' AND r.return_reason IS NOT NULL AND r.return_reason != ''
                    THEN 'INCONSISTENT'
                WHEN r.order_status IN ('RETURNED', 'CANCELLED')
                     AND (r.return_reason IS NULL OR r.return_reason = '')
                    THEN 'INCONSISTENT'
                ELSE 'OK'
            END
        FROM raw.sales_transaction r
        LEFT JOIN staging.sales_transaction existing ON r.sales_id::BIGINT = existing.sales_id
        WHERE r.batch_date = %s
          AND existing.sales_id IS NULL
          AND r.sales_id ~ '^\\d+$'
          AND r.quantity ~ '^\\d+$'
          AND r.gross_amount ~ '^\\d+(\\.\\d+)?$'
          AND r.discount_amount ~ '^\\d+(\\.\\d+)?$'
          AND r.tax_amount ~ '^\\d+(\\.\\d+)?$'
          AND r.net_amount ~ '^\\d+(\\.\\d+)?$'
          AND r.transaction_ts ~ '^\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}';
    """, (batch_date_str,))
    count = cur.rowcount
    cur.close()
    return count


# ============================================================
# STEP 4: DW MERGE -- SCD2 for customer/product, SCD1 for store,
# append-only for fact_sales
# ============================================================

def merge_dim_store(conn):
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO dw.dim_store
            (store_id, store_name, region, ownership_model, opening_date,
             city, state, country, latitude, longitude, store_status)
        SELECT store_id, store_name, region, ownership_model, opening_date,
               city, state, country, latitude, longitude, store_status
        FROM staging.store_information
        ON CONFLICT (store_id) DO UPDATE SET
            store_name = EXCLUDED.store_name,
            region = EXCLUDED.region,
            ownership_model = EXCLUDED.ownership_model,
            opening_date = EXCLUDED.opening_date,
            city = EXCLUDED.city,
            state = EXCLUDED.state,
            country = EXCLUDED.country,
            latitude = EXCLUDED.latitude,
            longitude = EXCLUDED.longitude,
            store_status = EXCLUDED.store_status;
    """)
    count = cur.rowcount
    cur.close()
    return count


def merge_dim_customer_scd2(conn, batch_date_str):
    cur = conn.cursor()

    # close out current versions whose tracked attributes changed
    cur.execute("""
        UPDATE dw.dim_customer d
        SET valid_to = %s::DATE - INTERVAL '1 day', is_current = FALSE
        FROM staging.customer s
        WHERE d.customer_id = s.customer_id
          AND d.is_current = TRUE
          AND (s.customer_name, s.dob, s.gender, s.kyc_type, s.kyc_number, s.onboard_date,
               s.status, s.loyalty_tier, s.city, s.state, s.country, s.email, s.phone, s.gdpr_opt_out)
              IS DISTINCT FROM
              (d.customer_name, d.dob, d.gender, d.kyc_type, d.kyc_number, d.onboard_date,
               d.status, d.loyalty_tier, d.city, d.state, d.country, d.email, d.phone, d.gdpr_opt_out);
    """, (batch_date_str,))
    closed = cur.rowcount

    # insert a fresh current version for anyone (new or changed) lacking one now
    cur.execute("""
        INSERT INTO dw.dim_customer
            (customer_id, customer_name, dob, gender, kyc_type, kyc_number, onboard_date,
             status, loyalty_tier, city, state, country, email, phone, gdpr_opt_out,
             valid_from, valid_to, is_current)
        SELECT
            s.customer_id, s.customer_name, s.dob, s.gender, s.kyc_type, s.kyc_number,
            s.onboard_date, s.status, s.loyalty_tier, s.city, s.state, s.country,
            s.email, s.phone, s.gdpr_opt_out,
            %s::DATE, '9999-12-31', TRUE
        FROM staging.customer s
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.dim_customer d
            WHERE d.customer_id = s.customer_id AND d.is_current = TRUE
        );
    """, (batch_date_str,))
    inserted = cur.rowcount
    cur.close()
    return closed, inserted


def merge_dim_product_scd2(conn, batch_date_str):
    cur = conn.cursor()

    cur.execute("""
        UPDATE dw.dim_product d
        SET valid_to = %s::DATE - INTERVAL '1 day', is_current = FALSE
        FROM staging.product_master s
        WHERE d.product_code = s.product_code
          AND d.is_current = TRUE
          AND (s.product_name, s.category, s.subcategory, s.brand, s.launch_date,
               s.mrp, s.tax_pct, s.product_status, s.last_price_revision)
              IS DISTINCT FROM
              (d.product_name, d.category, d.subcategory, d.brand, d.launch_date,
               d.mrp, d.tax_pct, d.product_status, d.last_price_revision);
    """, (batch_date_str,))
    closed = cur.rowcount

    cur.execute("""
        INSERT INTO dw.dim_product
            (product_code, product_name, category, subcategory, brand, launch_date,
             mrp, tax_pct, product_status, last_price_revision, valid_from, valid_to, is_current)
        SELECT
            s.product_code, s.product_name, s.category, s.subcategory, s.brand, s.launch_date,
            s.mrp, s.tax_pct, s.product_status, s.last_price_revision,
            %s::DATE, '9999-12-31', TRUE
        FROM staging.product_master s
        WHERE NOT EXISTS (
            SELECT 1 FROM dw.dim_product d
            WHERE d.product_code = s.product_code AND d.is_current = TRUE
        );
    """, (batch_date_str,))
    inserted = cur.rowcount
    cur.close()
    return closed, inserted


def append_fact_sales(conn):
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO dw.fact_sales
        SELECT
            s.sales_id, s.order_id, dd.date_key,
            COALESCE(c.customer_key, -1), COALESCE(p.product_key, -1), COALESCE(st.store_key, -1),
            s.sales_channel, s.quantity, s.gross_amount, s.discount_amount, s.tax_amount,
            s.net_amount, s.payment_mode, s.order_status, s.return_reason, s.return_reason_dq_flag
        FROM staging.sales_transaction s
        LEFT JOIN dw.fact_sales existing ON s.sales_id = existing.sales_id
        JOIN dw.dim_date dd ON s.transaction_ts::DATE = dd.full_date
        LEFT JOIN dw.dim_customer c ON s.customer_id = c.customer_id
             AND s.transaction_ts::DATE BETWEEN c.valid_from AND c.valid_to
        LEFT JOIN dw.dim_product p ON s.product_code = p.product_code
             AND s.transaction_ts::DATE BETWEEN p.valid_from AND p.valid_to
        LEFT JOIN dw.dim_store st ON s.store_id = st.store_id
        WHERE existing.sales_id IS NULL;
    """)
    count = cur.rowcount
    cur.close()
    return count


# ============================================================
# FILE MOVEMENT
# ============================================================

def move_file(filepath, dest_dir, batch_date_str):
    target_dir = os.path.join(dest_dir, batch_date_str)
    os.makedirs(target_dir, exist_ok=True)
    shutil.move(filepath, os.path.join(target_dir, os.path.basename(filepath)))


# ============================================================
# MAIN ORCHESTRATION
# ============================================================

def process_batch(batch_date_str):
    log.info(f"--- Processing batch: {batch_date_str} ---")
    batch_folder = os.path.join(INCOMING_DIR, batch_date_str)
    conn = get_connection()
    pending_processed_moves = []   # files to move to processed/ ONLY after final commit
    counts = {}

    # logged on its own connection so this row survives even if the
    # main transaction below later rolls back
    batch_id = log_batch_start(batch_date_str)

    try:
        loaded_any = False

        # 1) validate + load each file present in this batch folder
        for filename, (table_name, columns) in FILE_SPECS.items():
            filepath = os.path.join(batch_folder, filename)
            if not os.path.exists(filepath):
                continue  # nothing to do for this file today

            is_valid, reason = validate_file(filepath, columns)
            if not is_valid:
                log.warning(f"  INVALID {filename}: {reason} -> moving to junk/")
                move_file(filepath, JUNK_DIR, batch_date_str)
                continue

            success, result = try_load_raw_file(conn, filepath, table_name, columns, batch_date_str)
            if success:
                log.info(f"  Loaded {result} rows from {filename} into {table_name} "
                         f"(will move to processed/ once batch commits)")
                pending_processed_moves.append(filepath)   # DO NOT move yet
                loaded_any = True
            else:
                # a load failure is isolated via savepoint -- safe to junk immediately,
                # it has no bearing on whether the rest of the batch can still succeed
                log.warning(f"  LOAD FAILED for {filename}: {result} -> moving to junk/")
                move_file(filepath, JUNK_DIR, batch_date_str)

        if not loaded_any:
            log.info(f"  No valid files loaded for {batch_date_str}, skipping staging/dw stages.")
            conn.commit()
            log_batch_end(batch_id, "SUCCESS", counts, error_message="No valid files found")
            return

        # 2) staging: upsert masters, append-only sales
        counts["store_rows"] = upsert_staging_store(conn, batch_date_str)
        log.info(f"  staging.store_information: {counts['store_rows']} rows affected")
        counts["product_rows"] = upsert_staging_product(conn, batch_date_str)
        log.info(f"  staging.product_master: {counts['product_rows']} rows affected")
        counts["customer_rows"] = upsert_staging_customer(conn, batch_date_str)
        log.info(f"  staging.customer: {counts['customer_rows']} rows affected")
        counts["sales_rows"] = append_staging_sales(conn, batch_date_str)
        log.info(f"  staging.sales_transaction: {counts['sales_rows']} new rows appended")

        # 3) dw: SCD2 merges, SCD1 upsert, fact append
        n = merge_dim_store(conn)
        log.info(f"  dim_store: {n} rows upserted")
        closed, inserted = merge_dim_customer_scd2(conn, batch_date_str)
        counts["dim_customer_closed"], counts["dim_customer_inserted"] = closed, inserted
        log.info(f"  dim_customer: {closed} versions closed, {inserted} new versions inserted")
        closed, inserted = merge_dim_product_scd2(conn, batch_date_str)
        counts["dim_product_closed"], counts["dim_product_inserted"] = closed, inserted
        log.info(f"  dim_product: {closed} versions closed, {inserted} new versions inserted")
        counts["fact_rows"] = append_fact_sales(conn)
        log.info(f"  fact_sales: {counts['fact_rows']} new rows appended")

        # only now, after every stage succeeded, do we commit AND move files.
        # if anything above raised an exception, we'd never reach this point --
        # the except block below rolls back the DB and leaves files untouched
        # in incoming/ so the next run retries the whole batch cleanly.
        conn.commit()
        for filepath in pending_processed_moves:
            move_file(filepath, PROCESSED_DIR, batch_date_str)
        log.info(f"--- Batch {batch_date_str} committed successfully "
                 f"({len(pending_processed_moves)} files moved to processed/) ---")
        log_batch_end(batch_id, "SUCCESS", counts)

    except Exception as e:
        conn.rollback()
        log.error(f"  Batch {batch_date_str} FAILED, rolled back. "
                  f"Files with successful raw loads remain in incoming/ for retry. Error: {e}")
        log_batch_end(batch_id, "FAILED", counts, error_message=str(e))
        raise
    finally:
        conn.close()


def main():
    os.makedirs(INCOMING_DIR, exist_ok=True)
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    os.makedirs(JUNK_DIR, exist_ok=True)

    batches = get_pending_batches()
    if not batches:
        log.info("No pending batches found in data/incoming/. Nothing to do.")
        return

    for batch_date_str in batches:
        process_batch(batch_date_str)


if __name__ == "__main__":
    main()