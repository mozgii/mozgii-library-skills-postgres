-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Partition report: one row per partitioned table that is not itself a partition.
-- Run with: psql -X -f partition-report.sql -d <database>
-- Shows leaf count, total size, the default partition and its estimated rows
-- (-1 means never analyzed), and partitioned indexes that are still invalid.
WITH roots AS (
  SELECT c.oid, c.oid::regclass AS root, pg_get_partkeydef(c.oid) AS partition_key
  FROM pg_class c
  WHERE c.relkind = 'p' AND NOT c.relispartition
),
leaves AS (
  SELECT r.oid AS root_oid, t.relid, l.reltuples, pg_get_expr(l.relpartbound, l.oid) AS bound
  FROM roots r
  CROSS JOIN LATERAL pg_partition_tree(r.oid) t
  JOIN pg_class l ON l.oid = t.relid
  WHERE t.isleaf
)
SELECT r.root,
       r.partition_key,
       count(l.relid)                                                      AS leaves,
       pg_size_pretty(sum(pg_total_relation_size(l.relid)))               AS total_size,
       max(l.relid::regclass::text) FILTER (WHERE l.bound = 'DEFAULT')    AS default_partition,
       max(l.reltuples)              FILTER (WHERE l.bound = 'DEFAULT')    AS default_rows_estimate,
       (SELECT string_agg(i.indexrelid::regclass::text, ', ')
          FROM pg_index i WHERE i.indrelid = r.oid AND NOT i.indisvalid)   AS invalid_parent_indexes
FROM roots r
LEFT JOIN leaves l ON l.root_oid = r.oid
GROUP BY r.oid, r.root, r.partition_key
ORDER BY sum(pg_total_relation_size(l.relid)) DESC NULLS LAST;
