---
title: Drizzle migrations in depth
author: MOZGII, Inc.
lang: en
---

# Drizzle migrations in depth

This reference holds the production migration detail of the Drizzle skill: where migrations run, how `lock_timeout` and
concurrent indexes fit the migrator, how a breaking change ships over several deploys, which generated statements
lock or rewrite a live table, rollback, PGlite tests, seeding, and how migrations reach a database that the app
reaches through Hyperdrive.

## Contents

This reference covers the following migration topics.

- How the Drizzle migrator applies files: one transaction for everything pending
- Migrations run in CI, never at app boot
- Every production migration starts with lock_timeout
- Indexes on large tables: build them concurrently outside the migrator
- Renames, NOT NULL, foreign keys and enums in generated SQL
- Rollback is a forward fix
- Testing with PGlite
- Expand and contract instead of a generated rename
- Other DDL traps in generated SQL
- Seeding
- Drizzle on Cloudflare Workers with Hyperdrive
- Guarding drizzle-kit push

## How the Drizzle migrator applies files: one transaction for everything pending

drizzle-orm's PostgreSQL migrator, which `drizzle-kit migrate` and `migrate()` both use, runs every pending migration
file inside one transaction and splits files at `--> statement-breakpoint` comments. Three consequences:

- A failure in any pending file rolls back all of them: good for consistency.
- `CREATE INDEX CONCURRENTLY` (and anything else that refuses a transaction block) cannot run through the migrator
  at all: it fails with "CREATE INDEX CONCURRENTLY cannot run inside a transaction block".
- A long migration holds its locks until the last pending file finishes. Ship risky DDL in its own deploy.

Keep the `--> statement-breakpoint` comments: the migrator needs them to split statements.

## Migrations run in CI, never at app boot

In serverless and autoscaled apps, "boot" happens on every cold start of every instance, so boot-time migrations run
many migrators at once. A failed migration should fail the deploy, not crash-loop the app.

```
1. build + test + drizzle-kit check
2. migrate            ← its own job, direct URL, migration role, manual approval for production
3. deploy the new app version
4. a later release: contract / cleanup migration
```

Serialize the migrator with a session advisory lock so retried deploys and parallel jobs cannot overlap:

```ts
// scripts/migrate.ts
import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import { sql } from 'drizzle-orm';
import pg from 'pg';

const client = new pg.Client({ connectionString: process.env.DATABASE_URL_DIRECT });   // one session for the lock
await client.connect();
const db = drizzle({ client });
await db.execute(sql`SELECT pg_advisory_lock(hashtext('app-migrations'))`);
try {
  await migrate(db, { migrationsFolder: './drizzle' });
} finally {
  await db.execute(sql`SELECT pg_advisory_unlock(hashtext('app-migrations'))`);
  await client.end();
}
```

Step 2 must be backward-compatible with the code that is running: between migrate and deploy, the old code runs
against the new schema. That constraint is the reason expand and contract exists.

## Every production migration starts with lock_timeout

Without `lock_timeout`, an `ALTER TABLE` waits behind a long-running query while holding its place in the lock queue,
and every query that arrives after it waits too. Add these lines at the top of each generated file:

```sql
SET lock_timeout = '3s';
SET statement_timeout = '15min';
--> statement-breakpoint
```

`SET` runs inside the migrator's transaction, so it covers every file in the run. It does not end at the `COMMIT`: a
committed `SET` stays for the rest of the session (a rollback undoes it, and `SET LOCAL` ends at the commit, as tested
on 18.6). The migrate script below closes its own client, so nothing leaks; on a connection you reuse, use `SET LOCAL`
or `RESET` after the run. If a migration fails on the lock timeout, retry the job later.

## Indexes on large tables: build them concurrently outside the migrator

drizzle-kit emits a plain `CREATE INDEX`, which blocks writes for the whole build, and the migrator cannot run the
`CONCURRENTLY` form. Build the index before the migration, outside a transaction, and make the migration a no-op:

```bash
# CI step before "migrate", on the direct URL
psql "$DATABASE_URL_DIRECT" -v ON_ERROR_STOP=1 \
  -c "SET lock_timeout = '5s'" \
  -c 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "project_status_idx" ON "app"."project" ("status")'
```

```sql
-- the generated migration file, edited: IF NOT EXISTS makes it a no-op where the index already exists
CREATE INDEX IF NOT EXISTS "project_status_idx" ON "app"."project" USING btree ("status");
```

Fresh databases (tests, new environments) still get the index from the migration. If the concurrent build failed, it
left an `INVALID` index: drop it with `DROP INDEX CONCURRENTLY` and run the step again.

## Renames, NOT NULL, foreign keys and enums in generated SQL

drizzle-kit writes correct SQL for an empty database, not always safe SQL for a live one. Read every statement of a
generated file and rewrite these before merging:

| Generated | Problem on a live table | Ship instead |
|---|---|---|
| `RENAME COLUMN` (from the rename prompt) | breaks every running instance of the old code | answer "create column", then expand and contract over several deploys |
| `ADD COLUMN ... DEFAULT gen_random_uuid()` | volatile default rewrites the table | add the column bare, backfill in batches, then `SET DEFAULT` |
| `SET NOT NULL` from a new `.notNull()` | full scan under an exclusive lock | PG 18: `ADD CONSTRAINT ... NOT NULL col NOT VALID`, then `VALIDATE CONSTRAINT` |
| `ADD CONSTRAINT ... FOREIGN KEY` | scans and locks both tables | add it `NOT VALID`, validate in a later migration |
| `ALTER TYPE ... ADD VALUE` used in a later file of the same run | `unsafe use of new value` (the run is one transaction) | separate deploys, or `text` plus `check()` |
| `CREATE INDEX` on a big table | blocks writes for the build | build it `CONCURRENTLY` in a CI step before the migration |

The step-by-step table for a rename is in the next section.

## Rollback is a forward fix

There are no down migrations in Drizzle, and you do not want them: a down that drops a column you just backfilled
destroys data.

1. Every migration is expand-only, so the previous app version still runs on the new schema. Rollback means
   redeploying the previous version; the database does not change.
2. A bad migration is fixed with a new forward migration.
3. Backups and point-in-time recovery are for data corruption, not for "we shipped a bad ALTER".

This only holds if a destructive migration and the code change that needs it never ship in the same deploy.

## Testing with PGlite

PGlite is PostgreSQL compiled to WebAssembly and run in-process: real constraints, `ON CONFLICT` and types, no Docker.

```ts
import { PGlite } from '@electric-sql/pglite';
import { drizzle } from 'drizzle-orm/pglite';
import { migrate } from 'drizzle-orm/pglite/migrator';
import * as tables from '../src/db/schema';
import * as relations from '../src/db/relations';

const schema = { ...tables, ...relations };

export async function makeTestDb() {
  const client = new PGlite();
  const db = drizzle({ client, schema, casing: 'snake_case' });
  await migrate(db, { migrationsFolder: './drizzle' });   // run the real migrations, never push
  return { db, client };
}
```

PGlite cannot show pooler behaviour, per-request clients on Workers, prepared statements across connections or
extensions it lacks; keep one integration test against a real server in CI.

## Expand and contract instead of a generated rename

When a column disappears and another appears, drizzle-kit asks whether it is a rename and can generate
`ALTER TABLE ... RENAME COLUMN`. On a live system a rename breaks every running instance of the old code. Answer
"create column", and ship the change as expand and contract:

| Deploy | DDL | Code |
|---|---|---|
| 1 expand | `ADD COLUMN display_name text` | |
| 2 | | write both, read `full_name` |
| 3 backfill | batched updates (a script, not the migrator) | |
| 4 | | read `display_name`, still write both |
| 5 | `NOT NULL` the safe way: `NOT VALID`, then `VALIDATE CONSTRAINT` | |
| 6 | | stop writing `full_name` |
| 7 contract | `DROP COLUMN full_name` | |

## Other DDL traps in generated SQL

Read every generated statement; these are the common ones that lock or rewrite.

- A column added with a volatile default (`gen_random_uuid()`, `clock_timestamp()`) rewrites the table. Constant and
  stable defaults (`0`, `now()`) are instant on PostgreSQL 11 and later.
- `.notNull()` added to an existing column becomes `SET NOT NULL`, which scans the table under an exclusive lock;
  on PostgreSQL 18 replace it with `ADD CONSTRAINT ... NOT NULL ... NOT VALID` plus `VALIDATE CONSTRAINT`.
- A foreign key becomes `ADD CONSTRAINT ... FOREIGN KEY`; add `NOT VALID` and validate in a later migration.
- Enum values: `ALTER TYPE ... ADD VALUE` cannot be used in the same transaction, and the migrator runs all pending
  files in one, so a later file in the same run that uses the value fails. Ship it in separate deploys, or use
  `text` plus a `check()`.

## Seeding

Reference and lookup data (countries, plans, roles) belongs in a migration: it must exist in every environment.
Demo and fixture data belongs in a script that CI never runs against production. Seeds use the direct URL.

## Drizzle on Cloudflare Workers with Hyperdrive

drizzle-kit is a Node CLI and cannot use a Worker binding; it must not go through the pooler either. Migrations run
from CI with the direct URL; the Worker uses the Hyperdrive binding at run time.

## Guarding drizzle-kit push

`drizzle-kit push` applies the schema diff straight to a database with no file and no history, so block it where it
must never run. A script guard in `package.json` refuses it in production:

```jsonc
"db:push": "node -e \"if(process.env.NODE_ENV==='production'){console.error('push is not allowed in production');process.exit(1)}\" && drizzle-kit push"
```

Also give the production URL only to the CI migrate job, so a developer's `push` cannot reach it at all.
