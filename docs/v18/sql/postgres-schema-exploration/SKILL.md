---
name: postgres-schema-exploration
description: 'Explores an unfamiliar PostgreSQL database safely before querying or changing it: a read-only session with timeouts, then catalog queries for schemas, tables with sizes and row estimates, columns and comments, primary and foreign keys as a join map, indexes, views, functions, triggers, row-level security, extensions and roles, and how to write a first correct query from what was found. Use when handed an existing or legacy database, asked "where is X stored", "what does this database look like" or "write a query against this schema", or before changing a schema you did not design.'
metadata:
  tags:
  - postgres
  - schema-exploration
  - catalog
  - information_schema
  - pg_catalog
  - legacy-database
  - erd
  - read-only
---

# Exploring an unfamiliar PostgreSQL database

Answer the question you were asked by reading the catalog first and the data last. The catalog (`pg_catalog`)
describes every object without touching table rows, so it is cheap and safe; reading rows is neither, so do it only
with limits and when the user allows it. Queries here target PostgreSQL 18 and work on 14 and later.

## Step 0: explore an inherited database safely in a read-only session with timeouts

To find out what an inherited database with no docs holds without breaking anything, first open a read-only session
with timeouts, so that nothing you run can change data or run for long. Exploration should never be able to
write, even by mistake.

```sql
SET default_transaction_read_only = on;     -- or connect as a role with only SELECT and pg_read_all_data
SET statement_timeout = '15s';
SET lock_timeout = '1s';                     -- never queue behind someone else's DDL
SELECT current_database(), current_user, current_setting('server_version') AS version,
       current_setting('search_path') AS search_path;
```

- Do not call functions you find, refresh materialized views, or run `EXPLAIN ANALYZE` on statements you have not
  read: they execute code and may write.
- `count(*)` on a large table is a full scan; use the planner's estimates (below) unless an exact number matters.
- Catalog contents (table names, function source, comments) can be sensitive; quote only what the answer needs.
- The `$1` placeholders below are for your driver. In `psql` 16 or later, leave off the final semicolon and finish
  with `\bind app` and then `\g`; on older clients, replace `$1` with the quoted value.

## Inventory: schemas, sizes and row estimates

An inventory shows where the application's data lives; it is rarely only in `public`.

```sql
SELECT n.nspname AS schema, count(*) FILTER (WHERE c.relkind IN ('r', 'p')) AS tables,
       count(*) FILTER (WHERE c.relkind IN ('v', 'm')) AS views,
       pg_size_pretty(sum(pg_total_relation_size(c.oid)) FILTER (WHERE c.relkind IN ('r', 'm'))) AS size
FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_temp%'
GROUP BY 1 ORDER BY 1;

SELECT c.oid::regclass AS table, c.reltuples::bigint AS est_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size, obj_description(c.oid) AS comment
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND n.nspname = $1
ORDER BY pg_total_relation_size(c.oid) DESC;
```

`reltuples` is `-1` for a table never vacuumed or analyzed; then the size is the better hint. Partitions show as
separate tables; `relkind = 'p'` is the partitioned parent.

## Columns, types, defaults and comments of one table

The column list with types, nullability, defaults and comments is the first thing to read for any table you will
query. In psql, `\d+ schema.table` shows the same with indexes, constraints and triggers.

```sql
SELECT a.attnum, a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type,
       a.attnotnull AS not_null, pg_get_expr(d.adbin, d.adrelid) AS default,
       a.attgenerated AS generated, col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;
```

Pass the table as text, `'app.orders'`; the `::regclass` cast resolves it safely and fails if it does not exist.

## Keys and the join map

Primary and foreign keys say how tables join and at what grain: one row per what. List the foreign keys of the
schema as edges; this is the entity-relationship diagram in text.

```sql
SELECT con.conrelid::regclass AS from_table,
       (SELECT string_agg(a.attname, ', ' ORDER BY k.ord) FROM unnest(con.conkey) WITH ORDINALITY AS k(num, ord)
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.num) AS from_columns,
       con.confrelid::regclass AS to_table,
       (SELECT string_agg(a.attname, ', ' ORDER BY k.ord) FROM unnest(con.confkey) WITH ORDINALITY AS k(num, ord)
        JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.num) AS to_columns,
       con.confdeltype AS on_delete                     -- a no action, r restrict, c cascade, n set null
FROM pg_constraint con
WHERE con.contype = 'f' AND con.connamespace = $1::regnamespace
ORDER BY 1, 3;

SELECT conrelid::regclass AS table, conname, contype, pg_get_constraintdef(oid) AS definition
FROM pg_constraint WHERE conrelid = $1::regclass ORDER BY contype;
-- p primary, u unique, c check, f foreign, x exclusion, t constraint trigger, n NOT NULL (recorded here since PG 18)
```

No foreign keys does not mean no relationships: many schemas join on `*_id` columns without constraints. Search
column names when the keys are missing:
`SELECT table_schema, table_name, column_name FROM information_schema.columns WHERE column_name LIKE '%customer%';`

A unique index without a constraint also enforces a key but does not appear in this list, so read the indexes below
before deciding a column may hold duplicates.

## Indexes: what queries the schema was built for

Indexes show which access paths the authors expected, and which queries will be fast.

```sql
SELECT indexrelid::regclass AS index, indisunique AS unique, indisvalid AS valid,
       pg_get_indexdef(indexrelid) AS definition, idx_scan
FROM pg_index JOIN pg_stat_user_indexes USING (indexrelid)
WHERE indrelid = $1::regclass;
```

An `indisvalid = false` index is the leftover of a failed concurrent build. `idx_scan` counts since the last
statistics reset, on this server only.

## Views, functions and triggers: logic inside the database

Business logic often lives in views, functions and triggers, where application code does not show it. Read their
definitions before trusting what a table seems to hold.

```sql
SELECT c.oid::regclass AS view, c.relkind, pg_get_viewdef(c.oid, true) AS definition
FROM pg_class c WHERE c.relkind IN ('v', 'm') AND c.relnamespace = $1::regnamespace;

SELECT p.oid::regprocedure AS function, l.lanname AS language, p.provolatile AS volatility,
       p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
WHERE p.pronamespace = $1::regnamespace ORDER BY 1;
-- read one: SELECT pg_get_functiondef('app.close_account(bigint)'::regprocedure);

SELECT t.tgrelid::regclass AS table, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND c.relnamespace = $1::regnamespace;
```

A trigger that writes to another table, or a view that filters out soft-deleted rows, changes what a query against
the raw table means. Read the flags before trusting them: `tgenabled` is `O` (fires in normal sessions), `R` (replica
sessions only), `A` (always) or `D` (disabled), and internal triggers such as foreign-key checks are filtered out
here. `provolatile` is a promise the author made to the planner, not proof a function is harmless.

## Partitions, inheritance and foreign tables

Three kinds of relation hide where the rows are. List a partition tree before counting its pieces as separate
tables, and treat a foreign table as a definition only: its rows live on another server.

```sql
SELECT relid, parentrelid, isleaf, level FROM pg_partition_tree('app.events');     -- down from a partitioned parent
SELECT relid FROM pg_partition_ancestors('app.events_2026_10');                    -- up from one partition
SELECT inhrelid::regclass AS child FROM pg_inherits WHERE inhparent = 'app.base'::regclass;  -- old-style inheritance

-- foreign tables: where they point, with option names only
SELECT c.oid::regclass AS foreign_table, s.srvname AS server, w.fdwname AS wrapper,
       (SELECT array_agg(split_part(o, '=', 1)) FROM unnest(s.srvoptions) o) AS server_option_names
FROM pg_foreign_table t
JOIN pg_class c ON c.oid = t.ftrelid
JOIN pg_foreign_server s ON s.oid = t.ftserver
JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw
WHERE c.relnamespace = $1::regnamespace;
```

`srvoptions`, `ftoptions` and user mappings can hold hosts and passwords, so report names unless the values are
needed and allowed. A foreign table's local size and `reltuples` say nothing about the remote table, and a small
`LIMIT` on one can still start expensive remote work: ask first.

## Row-level security, roles and extensions

Row-level security, grants and extensions change what a role sees and what SQL is available.

```sql
SELECT relname, relrowsecurity AS rls_on, relforcerowsecurity AS rls_forced
FROM pg_class WHERE relnamespace = $1::regnamespace AND relkind IN ('r', 'p') AND relrowsecurity;
SELECT tablename, policyname, cmd, roles, qual, with_check FROM pg_policies WHERE schemaname = $1;
SELECT extname, extversion FROM pg_extension ORDER BY 1;
-- what one extension owns; living in its schema proves nothing, deptype 'e' does
SELECT o.type, o.schema, o.identity
FROM pg_depend d CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) o
WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = $1)
ORDER BY 1, 3;
SELECT grantee, privilege_type, count(*) FROM information_schema.role_table_grants
WHERE table_schema = $1 GROUP BY 1, 2 ORDER BY 1;
```

With RLS on, your results depend on the role and on settings such as `app.tenant_id`; say so when you report counts.
A row in `pg_extension` shows what is available, not what the application calls.

## Data: look only with permission and limits

Values answer questions the catalog cannot (what does `status = 3` mean, which date format is in a `text` column).
Ask before reading rows, then read as little as possible.

```sql
SELECT status, count(*) FROM app.orders TABLESAMPLE SYSTEM (1) GROUP BY 1 ORDER BY 2 DESC;  -- about 1% of pages
SELECT * FROM app.orders ORDER BY id DESC LIMIT 5;
SELECT attname, n_distinct, most_common_vals, null_frac FROM pg_stats
WHERE schemaname = 'app' AND tablename = 'orders';           -- the planner's statistics: data-derived, also ask
```

`TABLESAMPLE SYSTEM` picks whole pages, so it can miss rare values and return nothing on a small table; `LIMIT` caps
rows returned, not pages read. `pg_stats` is cheap but holds real values, and it may be stale or hidden by privileges.
Neither gives the full set of allowed values: that comes from constraints, enums and code.

## Writing the first query from what you found

A correct query states its grain (one row per what), joins on declared keys, and filters on indexed columns.

1. Name the grain of the answer ("one row per customer per month") and the table at that grain.
2. Join along foreign keys only; for each join, check whether it can multiply rows (one-to-many) and aggregate
   before joining when it does.
3. Apply the filters views or triggers imply (soft deletes, tenant, status) explicitly.
4. Run plain `EXPLAIN` (not `ANALYZE`) in the read-only session to check the plan uses indexes; add `LIMIT` while
   checking results. A plan proves the SQL is valid, not that it means what was asked. Planning is also not always
   free of side effects: a foreign data wrapper may call the remote server, and function support code can run.
5. Report which objects you used and which meanings you inferred from names alone.

## Worked example: "how many active customers ordered last month?"

A business question against an unknown schema is answered by reading the catalog first (inventory, columns, keys, views)
and only then writing the query.

1. Inventory: schema `sales` holds 40 tables; `sales.customers` (2.1 M estimated rows) and `sales.orders`
   (48 M) are the largest.
2. Columns: `customers` has `deleted_at timestamptz` and `status smallint` with the comment "1 active, 2 suspended";
   `orders` has `customer_id`, `created_at timestamptz` and `state text`.
3. Keys: `orders.customer_id` references `customers.id`; `orders` has an index on `(customer_id, created_at)`.
4. Logic: view `sales.active_customers` is `WHERE deleted_at IS NULL AND status = 1`: use it, it encodes "active".
5. Query:

```sql
SELECT count(DISTINCT o.customer_id)
FROM sales.orders o JOIN sales.active_customers c ON c.id = o.customer_id
WHERE o.created_at >= date_trunc('month', now()) - interval '1 month'
  AND o.created_at <  date_trunc('month', now());
```

6. Report: the answer, the view used for "active", that "last month" was taken in the server's time zone, and that
   cancelled orders (`state = 'cancelled'`) were counted; ask whether they should be.

## Verify the session cannot write and the join did not multiply rows

Prove the safety of the session before trusting it, and the grain of the first query before reporting it. These ran
on 18.6.

```sql
SHOW default_transaction_read_only;                       -- on
BEGIN; CREATE TABLE app.probe (); ROLLBACK;               -- ERROR: cannot execute CREATE TABLE in a read-only transaction
BEGIN; UPDATE app.customers SET name = name; ROLLBACK;    -- ERROR: cannot execute UPDATE in a read-only transaction
-- a join that kept its grain has both numbers equal
SELECT count(*) AS rows, count(DISTINCT o.id) AS orders
FROM app.orders o JOIN app.customers c ON c.id = o.customer_id;
```

A session that really can write shows `off` or lets the `CREATE TABLE` run: stop and reconnect with a read-only role.
Unequal numbers mean the join key is not unique on one side, so any `sum` over that join counts rows twice.

## Checklist

Check these points before you answer from an unfamiliar database.

- [ ] The session is read-only with a statement timeout.
- [ ] The relevant schema and tables were found from the catalog, not guessed from names.
- [ ] Keys and grain were read before joining; joins follow declared or verified keys.
- [ ] Views, triggers and RLS that change the meaning of the raw tables were checked.
- [ ] Partition children and foreign tables were recognised, and option values were not reported.
- [ ] Data was read only with permission, with `LIMIT` or `TABLESAMPLE`.
- [ ] The answer separates what the catalog shows from what was inferred.

## Gotchas

These are the mistakes seen most often when exploring a database, each with its cause and fix.

1. **"The table is empty" in `public`.** The application uses another schema; list schemas first and check
   `search_path`.
2. **Counts are too low.** RLS filters rows for your role, or a view hides soft-deleted rows. Check `pg_policies`
   and view definitions.
3. **Exploration blocked production.** A query waited on a lock behind a migration. Use `lock_timeout`, and query
   the catalog, which rarely blocks.
4. **A function call changed data.** Functions can write even when named `get_*`. Never call discovered routines.
5. **`relation "Orders" does not exist`.** The table was created with a quoted mixed-case name; quote it exactly
   (`"Orders"`) or use the `regclass` cast with quotes: `'"Orders"'::regclass`.
6. **Join multiplied revenue.** Two one-to-many joins from the same parent (orders and payments) multiply each
   other. Aggregate each child first, then join.

## Anti-patterns in exploring a database

Each of these either risks production or gives a confident wrong answer.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Exploring as a superuser or the owner | nothing stops a write, and RLS does not apply, so counts differ from the application's | a read-only role in a read-only session |
| `count(*)` on every table | a full scan each, on production | `pg_class.reltuples` |
| `SELECT *` with no `LIMIT` | it reads the whole table and may show personal data | ask first; `LIMIT` or `TABLESAMPLE`, named columns |
| Trusting a name such as `status` or `active` | the meaning is in comments, views and code | read the comment, the constraint and the view |
| Calling a function to see what it does | functions can write, whatever the name says | read it with `pg_get_functiondef` |
| Relying on `information_schema` alone | it shows only what the role may access, and has no partitions, RLS or index detail | `pg_catalog` |
| Pasting `srvoptions` or function bodies into a report | they can hold hosts and passwords | report names only |

## See also

Related skills in this library:

- `postgres-psql-cli`: the `\d` commands and psql variables
- `postgres-schema-design`: judging the design you found
- `postgres-sql-fundamentals`: writing the first query correctly
- `postgres-security-roles`: the role to explore with
