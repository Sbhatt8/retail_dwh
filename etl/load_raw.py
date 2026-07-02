import os
import psycopg2
from dotenv import load_dotenv

load_dotenv()  # reads the .env file into environment variables

conn = psycopg2.connect(
    host=os.getenv("DB_HOST"),
    port=os.getenv("DB_PORT"),
    dbname=os.getenv("DB_NAME"),
    user=os.getenv("DB_USER"),
    password=os.getenv("DB_PASSWORD")
)
conn.autocommit = True
cur = conn.cursor()

# --- Step 2a: create the 4 raw tables (all columns as TEXT) ---
create_statements = {
    "store_information": """
        CREATE TABLE IF NOT EXISTS raw.store_information (
            store_id TEXT, store_name TEXT, region TEXT, ownership_model TEXT,
            opening_date TEXT, city TEXT, state TEXT, country TEXT,
            latitude TEXT, longitude TEXT, store_status TEXT
        );
    """,
    "product_master": """
        CREATE TABLE IF NOT EXISTS raw.product_master (
            product_sk TEXT, product_code TEXT, product_name TEXT, category TEXT,
            subcategory TEXT, brand TEXT, launch_date TEXT, mrp TEXT,
            tax_pct TEXT, product_status TEXT, last_price_revision TEXT
        );
    """,
    "customer_management_system": """
        CREATE TABLE IF NOT EXISTS raw.customer_management_system (
            customer_sk TEXT, customer_id TEXT, customer_name TEXT, dob TEXT,
            gender TEXT, kyc_type TEXT, kyc_number TEXT, onboard_date TEXT,
            status TEXT, loyalty_tier TEXT, city TEXT, state TEXT, country TEXT,
            email TEXT, phone TEXT, last_updated_ts TEXT, gdpr_opt_out TEXT
        );
    """,
    "sales_transaction": """
        CREATE TABLE IF NOT EXISTS raw.sales_transaction (
            sales_id TEXT, order_id TEXT, transaction_ts TEXT, sales_channel TEXT,
            customer_id TEXT, product_code TEXT, store_id TEXT, quantity TEXT,
            gross_amount TEXT, discount_amount TEXT, tax_amount TEXT,
            net_amount TEXT, payment_mode TEXT, order_status TEXT, return_reason TEXT
        );
    """
}

for table_name, ddl in create_statements.items():
    cur.execute(ddl)
    print(f"Created (or already exists): raw.{table_name}")

cur.close()
conn.close()
print("Step 2a complete: all raw tables created.")