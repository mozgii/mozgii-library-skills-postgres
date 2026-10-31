-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Foreign data wrapper inventory: servers and options, user mappings (passwords and key passphrases masked), foreign
-- tables and their statistics, and this session's postgres_fdw connections. Pushdown is read per query with EXPLAIN.
-- Usage: psql -X -v ON_ERROR_STOP=1 -d <db> -f fdw-check.sql   (read-only). Tested on PostgreSQL 18.6.

\echo '== foreign servers'
SELECT s.srvname AS server, w.fdwname AS wrapper, pg_get_userbyid(s.srvowner) AS owner, s.srvoptions AS options
FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw
ORDER BY 1;

\echo '== user mappings (password and sslpassword values masked)'
SELECT m.srvname AS server, m.usename AS local_user,
       ARRAY(SELECT CASE WHEN o LIKE 'password=%' THEN 'password=***'
                         WHEN o LIKE 'sslpassword=%' THEN 'sslpassword=***' ELSE o END
             FROM unnest(umoptions) AS o) AS options,
       EXISTS (SELECT 1 FROM unnest(umoptions) o WHERE o LIKE 'password=%') AS stores_password,
       EXISTS (SELECT 1 FROM unnest(umoptions || s.srvoptions) o WHERE o = 'use_scram_passthrough=true')
         AS scram_passthrough
FROM pg_user_mappings m
JOIN pg_foreign_server s ON s.oid = m.srvid
ORDER BY 1, 2;

\echo '== foreign tables, options and local statistics'
SELECT ft.ftrelid::regclass AS foreign_table, s.srvname AS server, ft.ftoptions AS options,
       c.reltuples::bigint AS estimated_rows,
       greatest(pg_stat_get_last_analyze_time(ft.ftrelid),
                pg_stat_get_last_autoanalyze_time(ft.ftrelid)) AS last_analyze
FROM pg_foreign_table ft
JOIN pg_foreign_server s ON s.oid = ft.ftserver
JOIN pg_class c ON c.oid = ft.ftrelid
ORDER BY 1;

\echo '== open postgres_fdw connections of this session'
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgres_fdw') AS has_postgres_fdw \gset
\if :has_postgres_fdw
SELECT * FROM postgres_fdw_get_connections();
\endif
