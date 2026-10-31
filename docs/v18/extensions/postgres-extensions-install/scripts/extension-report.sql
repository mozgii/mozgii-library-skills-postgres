-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- extension-report.sql: read-only report of extensions in the current database and of the server's preload setup.
-- Run in every database that allows connections, for example:
--   for db in $(psql -XAtc "SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1"); do
--     psql -X -d "$db" -f extension-report.sql; done
-- Works on PostgreSQL 13 and later; the extension_control_path row is missing before 18.

\echo '== server, database'
SELECT current_setting('server_version') AS server_version, current_database() AS database;

\echo '== preload and search paths (preload changes need a restart)'
SELECT name, setting, pending_restart
FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'session_preload_libraries', 'local_preload_libraries',
               'dynamic_library_path', 'extension_control_path')
ORDER BY name;

\echo '== installed extensions, and whether the files on disk offer a newer version'
SELECT e.extname,
       e.extversion                      AS installed,
       a.default_version                 AS on_disk,
       e.extversion <> a.default_version AS needs_update,
       e.extnamespace::regnamespace      AS schema,
       e.extowner::regrole               AS owner
FROM pg_extension e
LEFT JOIN pg_available_extensions a ON a.name = e.extname
ORDER BY needs_update DESC NULLS FIRST, e.extname;

\echo '== statements to run here (empty when everything is current)'
SELECT format('ALTER EXTENSION %I UPDATE;', e.extname) AS run_this
FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extversion <> a.default_version
ORDER BY e.extname;

\echo '== installed extensions whose files are gone from this server (pg_upgrade and pg_restore will fail)'
SELECT e.extname, e.extversion
FROM pg_extension e
WHERE NOT EXISTS (SELECT 1 FROM pg_available_extensions a WHERE a.name = e.extname);
