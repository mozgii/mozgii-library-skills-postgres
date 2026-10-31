-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Least-privilege role setup for one application database (PostgreSQL 15 and later).
-- Run as a superuser, connected to the target database:  psql -X -v ON_ERROR_STOP=1 -d app -f roles-setup.sql
-- Passwords are not in this file: set them afterwards with  \password app_migrator  and  \password app_api
-- Rename "app" to your application's name throughout.

BEGIN;

CREATE ROLE app_owner NOLOGIN;                         -- owns the schema and every object in it
CREATE ROLE app_migrator LOGIN IN ROLE app_owner;      -- runs migrations; must SET ROLE app_owner first
CREATE ROLE app_rw NOLOGIN;                            -- data read and write
CREATE ROLE app_ro NOLOGIN;                            -- data read only
CREATE ROLE app_api LOGIN IN ROLE app_rw;              -- the application's login

SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO app_migrator, app_rw, app_ro', current_database()) \gexec

REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA app AUTHORIZATION app_owner;
GRANT USAGE ON SCHEMA app TO app_rw, app_ro;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT EXECUTE ON FUNCTIONS TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT ON TABLES TO app_ro;

ALTER ROLE app_api SET search_path = app;
ALTER ROLE app_api SET statement_timeout = '30s';
ALTER ROLE app_api SET lock_timeout = '5s';
ALTER ROLE app_api SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_migrator SET search_path = app;
ALTER ROLE app_migrator SET lock_timeout = '3s';

COMMIT;

-- Read back: the roles and their memberships
SELECT r.rolname, r.rolcanlogin, array_agg(m.rolname) FILTER (WHERE m.rolname IS NOT NULL) AS member_of
FROM pg_roles r
LEFT JOIN pg_auth_members am ON am.member = r.oid
LEFT JOIN pg_roles m ON m.oid = am.roleid
WHERE r.rolname LIKE 'app\_%'
GROUP BY r.rolname, r.rolcanlogin ORDER BY 1;
