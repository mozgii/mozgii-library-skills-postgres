-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Vacuum, bloat and wraparound report for PostgreSQL 18. Read-only.
-- Run: psql -X -v ON_ERROR_STOP=1 -d <database> -f vacuum-report.sql
-- Needs pg_monitor (or superuser); the index density part runs only when pgstattuple is installed.
\pset pager off

\echo '== 1. Tables by dead tuples, with the dead-tuple count that starts autovacuum'
SELECT s.relid::regclass AS table_name, s.n_live_tup, s.n_dead_tup, s.n_ins_since_vacuum,
       least(coalesce((SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                       WHERE option_name = 'autovacuum_vacuum_max_threshold'),
                      current_setting('autovacuum_vacuum_max_threshold')::bigint),
             coalesce((SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                       WHERE option_name = 'autovacuum_vacuum_threshold'),
                      current_setting('autovacuum_vacuum_threshold')::bigint)
           + coalesce((SELECT option_value::float8 FROM pg_options_to_table(c.reloptions)
                       WHERE option_name = 'autovacuum_vacuum_scale_factor'),
                      current_setting('autovacuum_vacuum_scale_factor')::float8) * greatest(c.reltuples, 0)
       )::bigint AS vacuum_at_dead,
       s.last_autovacuum, s.autovacuum_count, round(s.total_autovacuum_time / 1000) AS autovacuum_s
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
ORDER BY s.n_dead_tup DESC LIMIT 20;

\echo '== 2. What holds the xmin horizon back'
SELECT 'session' AS holder, pid::text AS id, state, age(backend_xmin) AS xmin_age, now() - xact_start AS xact_age
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid()
UNION ALL
SELECT 'prepared xact', gid, NULL, age(transaction), now() - prepared FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, NULL, greatest(age(xmin), age(catalog_xmin)), NULL FROM pg_replication_slots
WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL
UNION ALL
SELECT 'standby feedback', application_name, NULL, age(backend_xmin), NULL FROM pg_stat_replication
WHERE backend_xmin IS NOT NULL
ORDER BY xmin_age DESC NULLS LAST LIMIT 10;

\echo '== 3. HOT update ratio'
SELECT relid::regclass AS table_name, n_tup_upd, n_tup_hot_upd, n_tup_newpage_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd, 0), 1) AS hot_pct
FROM pg_stat_user_tables WHERE n_tup_upd > 0 ORDER BY n_tup_upd DESC LIMIT 20;

\echo '== 4. Database and table transaction ID age'
SELECT datname, age(datfrozenxid) AS xid_age, mxid_age(datminmxid) AS mxid_age,
       round(100.0 * age(datfrozenxid) / 2147483647, 1) AS pct_of_wrap
FROM pg_database ORDER BY 2 DESC;
SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age, mxid_age(c.relminmxid) AS mxid_age,
       current_setting('autovacuum_freeze_max_age')::bigint - age(c.relfrozenxid) AS xids_until_forced_vacuum,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC LIMIT 10;

\echo '== 5. Vacuums running now'
SELECT p.pid, p.relid::regclass AS table_name, p.phase,
       round(100.0 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0), 1) AS scanned_pct,
       p.index_vacuum_count, pg_size_pretty(p.dead_tuple_bytes) AS dead_items, p.delay_time,
       left(a.query, 80) AS query, now() - a.xact_start AS running
FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid);

\echo '== 6. Invalid indexes left by failed concurrent builds'
SELECT indexrelid::regclass AS index_name, indrelid::regclass AS table_name FROM pg_index WHERE NOT indisvalid;

\echo '== 7. Tables with per-table storage settings'
SELECT oid::regclass AS table_name, reloptions FROM pg_class
WHERE reloptions IS NOT NULL AND relkind IN ('r', 'm', 'p') ORDER BY 1;

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') AS has_pgstattuple \gset
\if :has_pgstattuple
\echo '== 8. Largest B-tree indexes and their leaf density (pgstatindex reads every page)'
SELECT i.indexrelid::regclass AS index_name, s.avg_leaf_density, s.leaf_fragmentation,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am ON am.oid = c.relam
CROSS JOIN LATERAL pgstatindex(i.indexrelid) s
WHERE am.amname = 'btree' AND i.indisvalid
  AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'pg_toast'::regnamespace)
ORDER BY pg_relation_size(i.indexrelid) DESC LIMIT 10;
\else
\echo '== 8. skipped: CREATE EXTENSION pgstattuple to measure index density'
\endif
