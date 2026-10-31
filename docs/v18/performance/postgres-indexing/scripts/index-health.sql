-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Index health report for PostgreSQL 13 and later. Read-only.
-- Run: psql -X -d app -f index-health.sql
-- Sections: unused indexes, duplicate indexes, invalid indexes, foreign keys without an index, largest indexes.

\echo '== Unused indexes (no scans since the last stats reset; not backing a constraint)'
SELECT s.schemaname, s.relname AS table_name, s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size, s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
ORDER BY pg_relation_size(s.indexrelid) DESC;

\echo '== Duplicate indexes (same table, keys, sort order, operator classes, collations, expression and predicate)'
SELECT indrelid::regclass AS table_name,
       array_agg(indexrelid::regclass ORDER BY indexrelid) AS indexes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS total_size
FROM pg_index
GROUP BY indrelid, indkey::text, indclass::text, indoption::text, indcollation::text,
         coalesce(indexprs::text, ''), coalesce(indpred::text, '')
HAVING count(*) > 1;

\echo '== Invalid indexes (left by a failed CREATE INDEX CONCURRENTLY; drop and rebuild)'
SELECT indexrelid::regclass AS index_name, indrelid::regclass AS table_name
FROM pg_index WHERE NOT indisvalid;

\echo '== Foreign keys whose columns do not lead any index'
SELECT c.conrelid::regclass AS table_name, c.conname AS constraint_name,
       array_agg(a.attname ORDER BY k.ord) AS columns
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND cardinality(c.conkey) <= i.indnkeyatts
      AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
  )
GROUP BY c.conrelid, c.conname;

\echo '== Largest indexes'
SELECT schemaname, relname AS table_name, indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size, idx_scan
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
