---
title: PostgreSQL row-level security in practice
author: MOZGII, Inc.
lang: en
---

# PostgreSQL row-level security in practice

This reference covers row-level security (RLS) policies for multi-tenant and per-user data: how policies combine,
how to pass the current user or tenant, how to keep RLS fast, and how to test it.

## How RLS policies work

With RLS enabled on a table, every query by a role without `BYPASSRLS` sees only rows that pass the table's
policies. If RLS is enabled and no policy applies to a command, that command sees no rows (default deny).

| Clause | Checked on | Applies to |
|---|---|---|
| `USING (expr)` | existing rows | `SELECT`, `UPDATE`, `DELETE` (which rows are visible or targetable) |
| `WITH CHECK (expr)` | new row versions | `INSERT`, `UPDATE` (what may be written) |

An `UPDATE` policy (or `ALL`) with no `WITH CHECK` reuses its `USING` for the new row, so the row cannot be handed to
another owner: changing `owner_id` fails with `new row violates row-level security policy`. Write `WITH CHECK`
separately only when the two rules differ.

Policies for the same command are combined with `OR` when `PERMISSIVE` (the default) and with `AND` when
`RESTRICTIVE`. Use a restrictive policy for a rule that must always hold, such as tenant isolation, and permissive
policies for the roles' specific rights.

## Which policies each command needs: why an UPDATE changes 0 rows

Row-level security fails quietly: a command that needs to read a row can only reach rows a `SELECT` policy shows it.
An `UPDATE` with a `WHERE` under an `UPDATE` policy alone reports `UPDATE 0`, with no error. Results measured on
PostgreSQL 18.6, role with table grants, RLS enabled.

| Statement | Policies it needs | Without them |
|---|---|---|
| `SELECT` | `SELECT` | 0 rows |
| `INSERT` | `INSERT` | `new row violates row-level security policy` |
| `INSERT ... RETURNING` | `INSERT` and `SELECT` | the same error, even though the plain insert works |
| `UPDATE ... WHERE col = ...` | `UPDATE` and `SELECT` | `UPDATE 0`, no error |
| `DELETE ... WHERE col = ...` | `DELETE` and `SELECT` | `DELETE 0`, no error |
| `INSERT ... ON CONFLICT DO UPDATE` | `INSERT`, `UPDATE` and `SELECT` | error |

Target roles are not authorization. `TO app_rw USING (true)` says "any session in this role", so one role shared by all
users reads every row. The row condition in `USING` has to say whose row it is.

## Passing the tenant or user to policies

Policies read the current tenant or user from a setting the application sets per transaction.

```sql
CREATE POLICY tenant_guard ON app.documents AS RESTRICTIVE FOR ALL TO app_rw
  USING (tenant_id = (SELECT nullif(current_setting('app.tenant_id', true), '')::bigint))
  WITH CHECK (tenant_id = (SELECT nullif(current_setting('app.tenant_id', true), '')::bigint));

CREATE POLICY members_read ON app.documents FOR SELECT TO app_rw
  USING (true);
CREATE POLICY owner_write ON app.documents FOR UPDATE TO app_rw
  USING (owner_id = (SELECT nullif(current_setting('app.user_id', true), '')::bigint));
```

- `current_setting('app.tenant_id', true)` returns NULL instead of an error when the setting was never used, so a
  forgotten setting matches no rows rather than failing open. Once a transaction on that connection has used
  `set_config(..., true)`, the same call returns an empty string, and `''::bigint` raises
  `invalid input syntax for type bigint`. `nullif(..., '')` makes both cases NULL, which matters on a pooled
  connection.
- Set the values with `set_config('app.tenant_id', $1, true)` at the start of each transaction. The `true` makes it
  local to the transaction, which is required behind transaction poolers.
- With Supabase, policies use `auth.uid()` and `auth.jwt()`, which read the request's JWT claims; the same
  performance rules apply. Three traps there: `auth.uid()` is NULL for a signed-out request, so state
  `auth.uid() IS NOT NULL` when that matters; a user can edit their own `raw_user_meta_data`, so never authorize from
  it (use `raw_app_meta_data`); and claims stay as issued until the token refreshes.

## Keeping RLS fast

A policy is a `WHERE` condition added to every query, so it needs indexes and must not run expensive functions per
row.

- Index the columns the policy filters on (`tenant_id`, `owner_id`), usually as the first column of composite indexes.
- Wrap function calls in a scalar subquery, `(SELECT current_setting(...))` or `(SELECT auth.uid())`, so the planner
  evaluates them once per query instead of once per row.
- Avoid joins inside policies on hot tables; for membership checks, use a `SECURITY DEFINER` function that returns the
  user's tenant ids as an array, wrapped in `(SELECT ...)`, and test with `= ANY(...)`. Such a function skips RLS on
  what it reads when its owner can, so keep it in a schema clients cannot reach, give it `SET search_path = ''`, check the caller inside
  it, and `REVOKE EXECUTE ... FROM PUBLIC`, because every new function is executable by everyone.
- Wrap a call in `(SELECT ...)` only when its result does not depend on the row.
- Check plans with `EXPLAIN` as the application role, not as a superuser (superusers bypass RLS and see a different
  plan).

## Testing RLS policies

RLS mistakes fail silently, so test them as the role the application uses.

```sql
BEGIN;
SET LOCAL ROLE app_api;
SELECT set_config('app.tenant_id', '1', true);
SELECT count(*) FROM app.documents WHERE tenant_id = 2;       -- must be 0
INSERT INTO app.documents (tenant_id, title) VALUES (2, 'x'); -- must fail: new row violates row-level security policy
ROLLBACK;
```

Run checks like these in CI against a real database (pgTAP or the app's test framework): for each table with RLS,
one test that another tenant's rows are invisible and one that writing them fails.

## RLS gotchas

These row-level security problems come up most often, each with its cause and fix.

1. **Owners and superusers bypass RLS.** `FORCE ROW LEVEL SECURITY` covers the owner; superusers and `BYPASSRLS`
   roles always bypass.
2. **Views run with the view owner's rights.** A view owned by the table owner bypasses RLS. Create views with
   `WITH (security_invoker = true)` (PG 15+).
3. **Foreign key checks and unique constraints ignore RLS.** A unique violation can reveal that another tenant's
   row exists; include `tenant_id` in unique keys.
4. **`pg_dump` as the app role stops with `query would be affected by row-level security policy for table`.** It sets
   `row_security = off` so a dump is never partial, and the role cannot bypass RLS. Run backups as a role that
   bypasses RLS. `pg_dump --enable-row-security` dumps only the rows the role can see, which is not a backup.
   `COPY ... TO` as the app role returns visible rows only, and `COPY ... FROM` fails with `COPY FROM not supported
   with row-level security`.
5. **`UPDATE 0` with no error.** The role has an `UPDATE` policy but no `SELECT` policy for that row, so the
   `WHERE` found nothing. Add the `SELECT` policy; see the command table above.
6. **Leaky functions.** A non-`LEAKPROOF` function in a query can see rows before the policy filters them only in
   rare plans; avoid custom functions that raise errors containing row data.
