import os
import io
import pandas as pd
import psycopg2
from dotenv import load_dotenv

load_dotenv()

conn = psycopg2.connect(
    host=os.getenv("DB_HOST"),
    port=os.getenv("DB_PORT"),
    dbname=os.getenv("DB_NAME"),
    user=os.getenv("DB_USER"),
    password=os.getenv("DB_PASSWORD")
)
conn.autocommit = True
cur = conn.cursor()

# map: raw table name -> csv file name
files_to_tables = {
    "store_information": "data/store_information.csv",
    "product_master": "data/product_master.csv",
    "customer_management_system": "data/customer_management_system.csv",
    "sales_transaction": "data/sales_transaction.csv"
}

for table_name, file_path in files_to_tables.items():
    print(f"Loading {file_path} into raw.{table_name} ...")

    # read everything as string, keep blanks as empty (not NaN)
    df = pd.read_csv(file_path, dtype=str, keep_default_na=False)

    # empty raw table before reload (safe to re-run this script)
    cur.execute(f"TRUNCATE TABLE raw.{table_name};")

    # write dataframe to an in-memory buffer as CSV (no header, no index)
    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False, sep="\t")
    buffer.seek(0)

    # fast bulk load using COPY
    cur.copy_expert(
        f"COPY raw.{table_name} FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t', NULL '')",
        buffer
    )

    cur.execute(f"SELECT COUNT(*) FROM raw.{table_name};")
    count = cur.fetchone()[0]
    print(f"  -> Loaded {count} rows into raw.{table_name}")

cur.close()
conn.close()
print("Step 2b complete: all CSVs loaded into raw schema.")