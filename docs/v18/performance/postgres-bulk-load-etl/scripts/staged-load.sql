-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Staged CSV load into app.products: COPY into an unlogged stage from psql's standard input, skip unconvertible rows
-- (at most 100), deduplicate, upsert only changed rows in one transaction, then report.
-- Usage (any OS; the CSV header must be sku,name,price,stock):
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f staged-load.sql < products.csv
-- Tested on PostgreSQL 18.6. Adapt table and column names for your feed.

\set ON_ERROR_STOP on
\timing on

CREATE SCHEMA IF NOT EXISTS app;
CREATE TABLE IF NOT EXISTS app.products (
  sku        text PRIMARY KEY,
  name       text NOT NULL,
  price      numeric(10,2) NOT NULL,
  stock      int,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNLOGGED TABLE IF NOT EXISTS app.products_stage (sku text, name text, price numeric(10,2), stock int);
TRUNCATE app.products_stage;

-- pstdin is psql's own standard input, even while it reads this script with -f
\copy app.products_stage FROM pstdin WITH (FORMAT csv, HEADER MATCH, ON_ERROR ignore, REJECT_LIMIT 100, LOG_VERBOSITY verbose)
ANALYZE app.products_stage;

\echo '== rows the target constraints would reject (fix the feed, they are skipped below)'
SELECT sku, name, price FROM app.products_stage
WHERE sku IS NULL OR name IS NULL OR price IS NULL;

\echo '== duplicate keys in the feed (one row per sku is kept, not a chosen one: fix the source)'
SELECT sku, count(*) FROM app.products_stage GROUP BY sku HAVING count(*) > 1;

BEGIN;
INSERT INTO app.products AS p (sku, name, price, stock)
SELECT DISTINCT ON (sku) sku, name, price, stock
FROM app.products_stage
WHERE sku IS NOT NULL AND name IS NOT NULL AND price IS NOT NULL
ORDER BY sku
ON CONFLICT (sku) DO UPDATE
  SET name = EXCLUDED.name, price = EXCLUDED.price, stock = EXCLUDED.stock, updated_at = now()
  WHERE (p.name, p.price, p.stock) IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.price, EXCLUDED.stock);
COMMIT;

\echo '== result'
SELECT (SELECT count(*) FROM app.products_stage) AS staged_rows,
       (SELECT count(*) FROM app.products) AS products,
       (SELECT count(*) FROM app.products WHERE updated_at >= now() - interval '1 minute') AS changed_just_now;
