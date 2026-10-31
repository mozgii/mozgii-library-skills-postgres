-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- constraint-audit.sql: read-only report of constraints that are not doing their full job.
-- Run: psql -X -f constraint-audit.sql "<connection string>"

\echo '== Constraints not validated or not enforced (PostgreSQL 18) =='
SELECT c.conrelid::regclass AS table_name,
       c.conname,
       CASE c.contype WHEN 'c' THEN 'check' WHEN 'f' THEN 'foreign key' WHEN 'n' THEN 'not null' END AS kind,
       c.convalidated AS validated,
       c.conenforced  AS enforced
FROM pg_constraint c
JOIN pg_namespace n ON n.oid = c.connamespace
WHERE c.conrelid <> 0
  AND (NOT c.convalidated OR NOT c.conenforced)
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;

\echo '== Domain constraints not validated =='
SELECT c.contypid::regtype AS domain_name, c.conname
FROM pg_constraint c
WHERE c.contypid <> 0 AND NOT c.convalidated
ORDER BY 1, 2;

\echo '== Foreign keys whose referencing columns lead no index =='
SELECT c.conrelid::regclass AS table_name, c.conname,
       array_agg(a.attname ORDER BY k.ord) AS fk_columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
WHERE c.contype = 'f' AND c.conenforced
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
      AND cardinality(c.conkey) <= i.indnkeyatts)
GROUP BY c.conrelid, c.conname
ORDER BY 1, 2;

\echo '== Deferrable constraints (cannot be ON CONFLICT arbiters) =='
SELECT conrelid::regclass AS table_name, conname, contype, condeferred AS initially_deferred
FROM pg_constraint
WHERE condeferrable
ORDER BY 1, 2;
