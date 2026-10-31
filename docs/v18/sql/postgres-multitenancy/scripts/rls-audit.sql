-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Tenant isolation audit. Run with: psql -X -f rls-audit.sql -d <database>
-- Set the tenant column name if yours differs: psql -v tenant_column=account_id -f rls-audit.sql
\if :{?tenant_column}
\else
  \set tenant_column tenant_id
\endif

-- 1. Tables that carry the tenant column: is RLS enabled and forced, and how many policies apply?
SELECT c.oid::regclass                         AS table_name,
       c.relrowsecurity                        AS rls_enabled,
       c.relforcerowsecurity                   AS rls_forced,
       count(p.polname)                        AS policies,
       count(p.polname) FILTER (WHERE NOT p.polpermissive) AS restrictive_policies,
       CASE WHEN NOT c.relrowsecurity THEN 'no RLS: a missing WHERE leaks other tenants'
            WHEN NOT c.relforcerowsecurity THEN 'not FORCEd: the owner bypasses policies'
            WHEN count(p.polname) = 0 THEN 'RLS on but no policy: every query returns nothing'
            ELSE 'ok' END                      AS finding
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = :'tenant_column' AND NOT a.attisdropped
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE c.relkind IN ('r', 'p')
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
GROUP BY c.oid, c.relrowsecurity, c.relforcerowsecurity
ORDER BY (CASE WHEN NOT c.relrowsecurity OR NOT c.relforcerowsecurity OR count(p.polname) = 0 THEN 0 ELSE 1 END), 1;

-- 2. Indexes on those tables whose first column is not the tenant column (each lookup crosses tenants).
SELECT i.indexrelid::regclass AS index_name, i.indrelid::regclass AS table_name,
       pg_get_indexdef(i.indexrelid) AS definition
FROM pg_index i
JOIN pg_attribute t ON t.attrelid = i.indrelid AND t.attname = :'tenant_column' AND NOT t.attisdropped
WHERE i.indkey[0] <> t.attnum
  AND i.indrelid::regclass::text NOT LIKE 'pg\_%'
ORDER BY 2, 1;

-- 3. Roles that bypass row-level security (superusers and BYPASSRLS) and can log in.
SELECT rolname, rolsuper, rolbypassrls
FROM pg_roles
WHERE (rolsuper OR rolbypassrls) AND rolcanlogin
ORDER BY 1;

-- 4. Views over tenant tables that run with the view owner's rights (no security_invoker).
SELECT DISTINCT v.oid::regclass AS view_name, pg_get_userbyid(v.relowner) AS view_owner,
       d.refobjid::regclass AS reads_table
FROM pg_class v
JOIN pg_rewrite r ON r.ev_class = v.oid
JOIN pg_depend d ON d.objid = r.oid AND d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
JOIN pg_class t ON t.oid = d.refobjid AND t.relrowsecurity
WHERE v.relkind = 'v'
  AND d.refobjid <> v.oid
  AND NOT coalesce('security_invoker=true' = ANY (v.reloptions) OR 'security_invoker=on' = ANY (v.reloptions), false)
ORDER BY 1;
