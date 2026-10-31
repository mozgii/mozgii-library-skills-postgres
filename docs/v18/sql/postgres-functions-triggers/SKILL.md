---
name: postgres-functions-triggers
description: 'Writes PostgreSQL functions, procedures and triggers that are correct and fast: SQL versus PL/pgSQL, volatility labels, procedures that COMMIT, errors and exception blocks, dynamic SQL with format(), BEFORE and AFTER, row and statement triggers with transition tables, triggers for updated_at, audit history and counters, constraint and event triggers, SECURITY DEFINER with a fixed search_path, and debugging. Use when adding a trigger or stored function, moving logic into the database, or when a trigger is slow, recursive, does not fire, or an index on a function returns wrong rows.'
metadata:
  tags:
  - postgres
  - plpgsql
  - functions
  - procedures
  - triggers
  - audit-log
  - event-triggers
  - security-definer
---

# PostgreSQL functions, procedures and triggers

Put logic in the database when every writer must obey it, whatever client or script runs the write: timestamps,
audit history, invariants a constraint cannot express. Keep the rest in the application, where it is easier to test,
deploy and scale. Examples target PostgreSQL 18; most work from 14.

## Step 0: list the functions and triggers that already exist

Existing triggers change what every write does, so read them before adding another.

```sql
SELECT p.oid::regprocedure AS function, l.lanname, p.provolatile, p.prosecdef
FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
WHERE p.pronamespace = 'app'::regnamespace ORDER BY 1;
SELECT t.tgrelid::regclass AS table, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid)
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND c.relnamespace = 'app'::regnamespace;
```

In psql, `\df+ app.*` lists functions and `\sf app.fn` prints one's source.

## SQL functions or PL/pgSQL

Write a function in plain SQL when it is one query: the planner can inline it into the calling query, which
PL/pgSQL never allows. Use PL/pgSQL for loops, conditions, variables and error handling.

```sql
-- SQL, standard body (PG 14+): parsed at creation, dependencies tracked, inlinable when simple
CREATE FUNCTION app.order_total(p_order bigint) RETURNS bigint
LANGUAGE sql STABLE
BEGIN ATOMIC
  SELECT coalesce(sum(qty * price_cents), 0) FROM app.order_lines WHERE order_id = p_order;
END;

-- PL/pgSQL: control flow and errors
CREATE FUNCTION app.reserve(p_sku text, p_qty int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE left_qty int;
BEGIN
  UPDATE app.stock SET qty = qty - p_qty WHERE sku = p_sku AND qty >= p_qty RETURNING qty INTO left_qty;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not enough stock for %', p_sku USING ERRCODE = 'P0001', HINT = 'reload the cart';
  END IF;
  RETURN left_qty;
END $$;
```

`CREATE OR REPLACE FUNCTION` cannot change the return type or argument names; drop and recreate the function, in
the same migration as everything that depends on it.

## Volatility: IMMUTABLE, STABLE, VOLATILE

The volatility label tells the planner how often a function's result can change, and a wrong label gives wrong
results, not only slow ones.

| Label | Promise | Allowed in | Examples |
|---|---|---|---|
| `IMMUTABLE` | same inputs give the same result forever | index expressions, generated columns, partition keys | `lower(text)`, arithmetic |
| `STABLE` | same result within one statement; reads the database, no writes | normal queries, index conditions | lookups, `now()` |
| `VOLATILE` (default) | may change on every call or write | anywhere, evaluated per row | `random()`, functions that write |

- An index on a function labelled `IMMUTABLE` that reads a table or a setting returns stale rows after that data
  changes. Never label a function `IMMUTABLE` to get it into an index unless it really is.
- Add `PARALLEL SAFE` to functions that do not write or use temporary state, or queries calling them cannot run in
  parallel.
- `STRICT` returns NULL for any NULL argument without running the body.

## Procedures that commit in batches

A procedure (`CREATE PROCEDURE`, run with `CALL`) can `COMMIT` and `ROLLBACK` inside its body, which a function
cannot; that makes it the tool for batched maintenance inside the database.

```sql
CREATE PROCEDURE app.purge_old_events(batch int DEFAULT 10000)
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  LOOP
    DELETE FROM app.events WHERE id IN (
      SELECT id FROM app.events WHERE created_at < now() - interval '90 days' LIMIT batch);
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
    COMMIT;                                    -- each batch is its own transaction
  END LOOP;
END $$;
CALL app.purge_old_events();
```

`CALL` with a `COMMIT` inside must not run within an outer transaction block: drivers that open a transaction
implicitly (psycopg, JDBC with autocommit off) need autocommit for the `CALL`.

## Errors and exception blocks

`RAISE EXCEPTION` aborts the statement with an SQLSTATE the application can match; an `EXCEPTION` block catches
errors, but each block entry starts a subtransaction, which costs time and transaction ids.

```sql
BEGIN
  INSERT INTO app.tags (name) VALUES (p_name);
EXCEPTION WHEN unique_violation THEN
  NULL;                                         -- already there
END;
```

- Prefer conditions that avoid the error (`INSERT ... ON CONFLICT DO NOTHING`) to catching it, especially in loops:
  thousands of subtransactions in one transaction slow every session.
- Use your own SQLSTATE class (`P0001` with a message, or a code like `'AP001'`) for business errors, and
  `GET STACKED DIAGNOSTICS` to read the original error inside a handler.

## Dynamic SQL with format() and EXECUTE ... USING

Dynamic SQL builds a statement at run time, so it is the one place in the database where injection is possible.
Quote identifiers with `%I`, pass values with `USING`.

```sql
CREATE FUNCTION app.count_rows(p_table text) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM app.%I WHERE created_at > $1', p_table)
    INTO n USING now() - interval '1 day';
  RETURN n;
END $$;
```

Never concatenate input into the string (`'... WHERE name = ''' || p_name || ''''`); `%L` is for literals when
`USING` cannot be used.

## Trigger types: BEFORE or AFTER, row or statement

A trigger runs a function on `INSERT`, `UPDATE`, `DELETE` or `TRUNCATE`. Choose the kind by what it must do.

| Kind | Sees | Use for |
|---|---|---|
| `BEFORE ... FOR EACH ROW` | `NEW` (can change it), `OLD` | setting or normalizing columns (`updated_at`), rejecting a row |
| `AFTER ... FOR EACH ROW` | final `NEW` and `OLD` | side effects on other tables (audit, queue rows) |
| `AFTER ... FOR EACH STATEMENT` with `REFERENCING NEW TABLE AS ...` | all changed rows as a table | bulk audit and aggregates: one call per statement, not per row |
| `INSTEAD OF ... FOR EACH ROW` on a view | `NEW`, `OLD` | making a view writable |
| `CONSTRAINT TRIGGER ... DEFERRABLE` | like `AFTER ROW`, can run at commit | checks across rows that must hold at commit |

- `WHEN (OLD.status IS DISTINCT FROM NEW.status)` on the trigger skips the function call entirely for rows that do
  not need it.
- Triggers fire in alphabetical order of their names for the same event and timing.
- Row triggers created on a partitioned table are created on every partition.

## Trigger for updated_at

A `BEFORE UPDATE` row trigger keeps `updated_at` correct for every writer, including scripts and other services.

```sql
CREATE FUNCTION app.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER customers_updated_at BEFORE UPDATE ON app.customers
FOR EACH ROW WHEN (OLD IS DISTINCT FROM NEW) EXECUTE FUNCTION app.set_updated_at();
```

`now()` is the transaction's start time, so every row changed in one transaction gets the same value; use
`clock_timestamp()` for the wall-clock time.

## Trigger for an audit history table

An audit trigger copies each change into a history table, so "who changed this and what was it before" has an
answer. A statement-level trigger with transition tables writes a whole batch in one insert.

```sql
CREATE TABLE app.audit_log (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name text NOT NULL,
  op         text NOT NULL,
  row_id     bigint,
  old_row    jsonb,
  new_row    jsonb,
  actor      text NOT NULL DEFAULT coalesce(nullif(current_setting('app.user_id', true), ''), current_user),
  at         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION app.audit_rows() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO app.audit_log (table_name, op, row_id, new_row)
    SELECT TG_TABLE_NAME, TG_OP, n.id, to_jsonb(n) FROM new_rows n;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO app.audit_log (table_name, op, row_id, old_row, new_row)
    SELECT TG_TABLE_NAME, TG_OP, n.id, to_jsonb(o), to_jsonb(n)
    FROM new_rows n JOIN old_rows o USING (id);
  ELSE
    INSERT INTO app.audit_log (table_name, op, row_id, old_row)
    SELECT TG_TABLE_NAME, TG_OP, o.id, to_jsonb(o) FROM old_rows o;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER customers_audit_ins AFTER INSERT ON app.customers
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION app.audit_rows();
CREATE TRIGGER customers_audit_upd AFTER UPDATE ON app.customers
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION app.audit_rows();
CREATE TRIGGER customers_audit_del AFTER DELETE ON app.customers
  REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION app.audit_rows();
```

- The application passes the user with `SELECT set_config('app.user_id', $1, true)` at the start of each
  transaction, so the actor is the person, not the shared database role. Once a session has set it, the setting reads
  as an empty string outside that transaction, not NULL, which is why the default needs `nullif` (seen on 18.6).
- Transition tables need one trigger per event (a trigger with `REFERENCING` cannot list several events).
- Partition or prune the audit table by time; it grows with every write.
- For compliance logging of reads and DDL as well, the `pgaudit` extension logs to the server log instead.

## Counters kept by triggers, and the hot-row problem

A trigger that increments a counter on the parent row (`projects.task_count`) serializes every insert for that
parent on one row lock, so a busy parent becomes a queue.

- Compute on read with an index (`count(*) WHERE project_id = $1`) until it is measured to be too slow.
- When a stored counter is needed, append deltas to a side table (`INSERT INTO app.task_count_deltas VALUES ($1, 1)`)
  and fold them into the parent periodically.
- Never update the same table from its own `AFTER` row trigger without a guard: it fires itself again.

## Constraint triggers and deferred checks

A constraint trigger can be `DEFERRABLE INITIALLY DEFERRED`, so it checks at commit, after every statement of the
transaction has run. It enforces rules across rows ("an order has at least one line") that a `CHECK` cannot.

```sql
CREATE FUNCTION app.order_has_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app.order_lines WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'order % has no lines', NEW.id USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER orders_need_lines AFTER INSERT ON app.orders
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.order_has_lines();
```

Such checks are not race-free under `READ COMMITTED` (a concurrent transaction can delete the last line); use
`SERIALIZABLE` or row locks when the rule must hold under concurrency.

## Event triggers for DDL

Event triggers fire on DDL (`ddl_command_end`, `sql_drop`, `table_rewrite`, and in PG 17+ `login`), not on data
changes. They need superuser and suit logging or guarding schema changes.

```sql
CREATE FUNCTION app.log_ddl() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
    RAISE LOG 'DDL by %: % %', current_user, r.command_tag, r.object_identity;
  END LOOP;
END $$;
CREATE EVENT TRIGGER log_ddl ON ddl_command_end EXECUTE FUNCTION app.log_ddl();
```

A broken `login` event trigger can lock every user out; test it on a scratch server, and know that
`event_triggers = off` (PG 17+) in a superuser session disables them.

## SECURITY DEFINER functions

A `SECURITY DEFINER` function runs with its owner's rights, which lets a weak role perform one privileged action.
Without a fixed `search_path` a caller can plant an object that the function then runs with those rights.

```sql
CREATE FUNCTION app.close_account(p_id bigint) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
BEGIN ATOMIC
  UPDATE app.accounts SET closed_at = now() WHERE id = p_id;
END;
REVOKE ALL ON FUNCTION app.close_account(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.close_account(bigint) TO app_support;
```

New functions are executable by `PUBLIC` by default; revoke that for anything privileged, or set
`ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` for the owner role.

## Worked example: "keep a history of every change to customers"

An audit history needs a table, one trigger function, three triggers and the user id passed in by the application.

1. Create `app.audit_log` and the statement-level `app.audit_rows()` function from the audit section.
2. Add the three `REFERENCING` triggers to `app.customers` in a migration.
3. In the application, run `SELECT set_config('app.user_id', $1, true)` as the first statement of each
   transaction that writes customers.
4. Test inside a rolled-back transaction:

```sql
BEGIN;
SELECT set_config('app.user_id', 'u-42', true);
UPDATE app.customers SET name = 'Ann B.' WHERE id = 1;
SELECT op, actor, old_row->>'name' AS before, new_row->>'name' AS after FROM app.audit_log ORDER BY id DESC LIMIT 1;
-- UPDATE | u-42 | Ann | Ann B.
ROLLBACK;
```

5. Check the cost: a bulk `UPDATE` of 100,000 rows calls the function once, not 100,000 times.

## Verify a function or trigger before shipping it

These checks prove the code runs, fires once for what it should, and left nothing unsafe, with no rows kept.

```sql
SELECT p.oid::regprocedure FROM pg_proc p
WHERE p.prosecdef AND p.proconfig IS NULL AND p.pronamespace = 'app'::regnamespace;    -- expect no rows
SELECT count(*) FROM pg_trigger WHERE tgrelid = 'app.customers'::regclass AND NOT tgisinternal AND tgenabled = 'D';  -- expect 0
```

Debugging tools (`RAISE NOTICE`, `track_functions`, `auto_explain`) are in
[references/testing-debugging.md](references/testing-debugging.md). Then run the rolled-back trigger test from the
worked example. Set `plpgsql.extra_errors = 'all'` while creating
functions in a test database: PL/pgSQL only reports most other mistakes when the line runs, so call each branch in a
test.

## Checklist

Check these points before you call database functions or triggers done.

- [ ] The logic must hold for every writer; otherwise it lives in the application.
- [ ] One-statement functions are `LANGUAGE sql`; volatility labels are true; `PARALLEL SAFE` where it is.
- [ ] Dynamic SQL uses `format('%I')` and `EXECUTE ... USING`.
- [ ] Triggers use `WHEN` to skip rows, statement level with transition tables for bulk work.
- [ ] No trigger updates its own table without a guard; no hot counter rows.
- [ ] `SECURITY DEFINER` functions set `search_path` and revoke `EXECUTE` from `PUBLIC`.
- [ ] Functions and triggers ship in migrations and have tests that roll back.

## Gotchas

These are the failures seen most often with functions and triggers, each with its cause and fix.

1. **`stack depth limit exceeded` from a trigger.** An `AFTER UPDATE` trigger updates its own table and fires
   itself. Set the value in a `BEFORE` trigger on `NEW`, or guard with `WHEN (pg_trigger_depth() < 1)`.
2. **The trigger did not fire.** `TRUNCATE` does not fire `DELETE` triggers (add `ON TRUNCATE`); a session with
   `session_replication_role = replica` (logical replication apply, some restore tools) skips ordinary triggers;
   `ALTER TABLE ... DISABLE TRIGGER` was left on.
3. **An expression index returns wrong rows.** The function was labelled `IMMUTABLE` but reads a table or setting.
   Fix the label, then `REINDEX` the index.
4. **`cannot change return type of existing function`.** `CREATE OR REPLACE` keeps the signature; `DROP FUNCTION`
   and create it again in one migration.
5. **A loop with an `EXCEPTION` block got slow.** Each pass starts a subtransaction. Avoid the error with
   `ON CONFLICT` or a check, and keep exception blocks outside loops.
6. **`invalid transaction termination` on `COMMIT` in a procedure.** It was called inside a transaction block or
   from a function. `CALL` it with autocommit on.
7. **A `SECURITY DEFINER` function was hijacked.** No `SET search_path`; an attacker created `pg_temp` or `public`
   objects with the same names. Fix the path and schema-qualify every name.

## Anti-patterns in functions and triggers

| Do not | Do this instead |
|---|---|
| label a function `IMMUTABLE` to get it into an index | a real immutable expression, or a stored column |
| concatenate input into dynamic SQL | `format('%I')` and `EXECUTE ... USING` |
| catch errors inside a tight loop | avoid the error with `ON CONFLICT`, or check first |
| update a parent counter from a row trigger | count on read, or fold deltas later |
| use a `SECURITY DEFINER` function with no `SET search_path` | a fixed path, and `REVOKE` from `PUBLIC` |
| put business logic in triggers that one service owns | the application, where it is tested and deployed |

## See also

- `postgres-constraints-integrity`: rules a constraint can hold, and cross-row invariants.
- `postgres-auditing-compliance`: pgaudit, and where row history fits.
- `postgres-transactions-locking`: isolation and retries.
- `postgres-security-roles`: `SECURITY DEFINER`, roles and grants.
- `postgres-schema-migrations`: shipping functions safely.
- `postgres-testing-ci`: pgTAP and rollback tests.

## Sources

- https://www.postgresql.org/docs/18/xfunc.html, /plpgsql.html, /sql-createfunction.html, /sql-createprocedure.html
- https://www.postgresql.org/docs/18/trigger-definition.html, /sql-createtrigger.html, /event-triggers.html
- https://www.postgresql.org/docs/18/functions-admin.html (`current_setting`, `set_config`)
