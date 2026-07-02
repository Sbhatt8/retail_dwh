-- ============================================================
-- STEP 5: BUILD dim_date
-- Grain: one row per calendar day.
-- Range: wide enough to cover dob (decades back) through
-- transaction dates and any near-future planning needs.
-- Adjust start_date/end_date below once you've confirmed the
-- actual min/max from staging (see Step 5a query).
-- ============================================================

CREATE TABLE dw.dim_date (
    date_key        INTEGER PRIMARY KEY,   -- YYYYMMDD, e.g. 20260702
    full_date       DATE NOT NULL UNIQUE,
    day_of_month    INTEGER,
    day_name        TEXT,
    day_of_week     INTEGER,               -- 1=Monday .. 7=Sunday
    is_weekend      BOOLEAN,
    month_num       INTEGER,
    month_name      TEXT,
    quarter         INTEGER,
    year            INTEGER,
    fiscal_year     INTEGER,               -- Indian FY: Apr-Mar; adjust if not needed
    year_month      TEXT                   -- e.g. '2026-07', handy for grouping/sorting
);

INSERT INTO dw.dim_date
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER                            AS date_key,
    d                                                           AS full_date,
    EXTRACT(DAY FROM d)::INTEGER                                AS day_of_month,
    TO_CHAR(d, 'Day')                                           AS day_name,
    EXTRACT(ISODOW FROM d)::INTEGER                             AS day_of_week,
    EXTRACT(ISODOW FROM d) IN (6, 7)                            AS is_weekend,
    EXTRACT(MONTH FROM d)::INTEGER                              AS month_num,
    TO_CHAR(d, 'Month')                                         AS month_name,
    EXTRACT(QUARTER FROM d)::INTEGER                            AS quarter,
    EXTRACT(YEAR FROM d)::INTEGER                               AS year,
    -- Indian fiscal year: Apr(4)-Mar(3). FY2026 = Apr 2025 - Mar 2026.
    CASE
        WHEN EXTRACT(MONTH FROM d) >= 4 THEN EXTRACT(YEAR FROM d)::INTEGER + 1
        ELSE EXTRACT(YEAR FROM d)::INTEGER
    END                                                          AS fiscal_year,
    TO_CHAR(d, 'YYYY-MM')                                       AS year_month
FROM generate_series(
        '1970-01-01'::DATE,
        '2035-12-31'::DATE,
        '1 day'::INTERVAL
     ) AS d;

-- ============================================================
-- Verification
-- ============================================================

-- Should be one row per day in the range (~24,107 rows for 1970-2035)
SELECT COUNT(*) FROM dw.dim_date;

-- Spot check today's row
SELECT * FROM dw.dim_date WHERE full_date = CURRENT_DATE;

-- Confirm no gaps: count should equal (max_date - min_date + 1)
SELECT
    COUNT(*) AS row_count,
    (MAX(full_date) - MIN(full_date) + 1) AS expected_count
FROM dw.dim_date;

-- Confirm every date in staging.sales_transaction has a match in dim_date
-- (should return 0 rows -- if not, widen the range above and rebuild)
SELECT COUNT(*)
FROM staging.sales_transaction s
LEFT JOIN dw.dim_date d ON s.transaction_ts::DATE = d.full_date
WHERE d.date_key IS NULL;
