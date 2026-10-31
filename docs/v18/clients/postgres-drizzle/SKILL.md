---
name: postgres-drizzle
description: 'Uses Drizzle ORM with PostgreSQL in TypeScript and ships its migrations safely: the 0.45 stable versus 1.0 release-candidate trap, clients for Node servers and serverless runtimes, schema with identity keys and timestamptz, relations, drizzle-zod validators, db.query versus db.select, transactions with tx, upserts and keyset pages, drizzle-kit generate and migrate (never push in production), CI migrations under an advisory lock, concurrent indexes outside the migrator, Next.js rules and PGlite tests. Use for any Drizzle schema, query or migration work.'
metadata:
  tags:
  - postgres
  - drizzle
  - drizzle-kit
  - typescript
  - orm
  - migrations
  - nextjs
  - drizzle-zod
  - pglite
---

# Drizzle ORM with PostgreSQL

Schema, client, queries, validation and migrations for a TypeScript app on Drizzle and PostgreSQL, checked against
drizzle-orm 0.45.4, drizzle-kit 0.31.11 and drizzle-zod 0.8.3 (October 2026). Detail:
[migrations in depth](references/migrations.md) (expand and contract, generated SQL that locks, seeding),
[Next.js and Cloudflare Workers](references/nextjs.md) (`'use cache'`, Server Actions, OpenNext client).

## Step 0: drizzle-orm 0.45 stable versus the 1.0 release candidate

`defineRelations()` and Relational Queries v2 do not exist in the version a plain install gives you, so read what the
project has installed first (`npm ls drizzle-orm drizzle-kit drizzle-zod typescript`).

```
drizzle-orm   latest = 0.45.4        ← what `npm install drizzle-orm` installs (October 2026)
drizzle-orm   rc     = 1.0.0-rc.5    ← where defineRelations() and object-style where: { id: 1 } live
```

Many recent articles show the v1 API without saying it needs `@rc`; that code does not compile against 0.45. Pin the
stable line unless the team has chosen the RC:

```
drizzle-orm  0.45.4
drizzle-kit  0.31.11   (devDependencies only: it bundles esbuild)
drizzle-zod  0.8.3
```

Write 0.45 code so the move to v1 is cheap: keep all relations in one `relations.ts` (v1 replaces that file) and
all drizzle-zod imports in one `validators.ts` (v1 folds validators into `drizzle-orm/zod`). Check again when
`npm view drizzle-orm version` prints `1.x`.

## The database client on a long-lived Node server

On a Node server (`next start`, a container, a VM) create one pool per process and reuse it. In development, hot
reload re-evaluates modules, so keep the pool on `globalThis` or every save opens a new pool.

```ts
// src/db/index.ts
import 'server-only';                      // a stray client-side import becomes a build error, not a leaked URL
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import * as tables from './schema';
import * as relations from './relations';

const schema = { ...tables, ...relations };
const globalForDb = globalThis as unknown as { pool?: Pool };
const pool = globalForDb.pool ?? new Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
if (process.env.NODE_ENV !== 'production') globalForDb.pool = pool;

export const db = drizzle({ client: pool, schema, casing: 'snake_case' });
```

`drizzle-orm/postgres-js` with postgres.js is an equally good choice on Node.

## The database client on serverless and edge runtimes

Serverless and edge runtimes start many short-lived instances, so the client must match the platform. A pool at
module scope is right on a Node server and wrong on Cloudflare Workers, where an I/O object cannot cross a request
and a module-scope client fails with "Cannot perform I/O on behalf of a different request".

| Runtime | Client |
|---|---|
| Node server, container, VM | one `Pool` per process (above) |
| AWS Lambda, Vercel Functions on Node | a small `Pool` (`max: 1` to `5`) created outside the handler, through a transaction-mode pooler URL |
| Cloudflare Workers | a `pg` `Client` per request from the Hyperdrive binding, closed after the response |
| Neon from an edge runtime | `drizzle-orm/neon-http` with `@neondatabase/serverless` (HTTP; no interactive transactions) |

On Workers use `node-postgres`: Cloudflare documents Drizzle with postgres.js over Hyperdrive as unsupported, and the
`neon-*` drivers bypass Hyperdrive. The Worker handler, and the form for Next.js on Workers (OpenNext), are in
[references/nextjs.md](references/nextjs.md).

## Schema conventions

The schema file defines tables in TypeScript; drizzle-kit turns changes into SQL migrations.

```ts
// src/db/schema.ts
import { sql } from 'drizzle-orm';
import {
  pgTable, pgSchema, text, bigint, boolean, timestamp, jsonb, index, uniqueIndex, check,
} from 'drizzle-orm/pg-core';

export const app = pgSchema('app');

type Prefs = { theme: 'light' | 'dark'; locale: string };

export const appUser = app.table('app_user', {
  id: text().primaryKey(),                                  // the auth provider's user id
  email: text(),
  role: text().notNull().default('member'),
  prefs: jsonb().$type<Prefs>().notNull().default(sql`'{}'::jsonb`),
  createdAt: timestamp({ withTimezone: true, mode: 'date' }).notNull().defaultNow(),
  updatedAt: timestamp({ withTimezone: true, mode: 'date' }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => [check('app_user_role', sql`${t.role} IN ('admin', 'member', 'viewer')`)]);

export const project = app.table('project', {
  id: bigint({ mode: 'number' }).primaryKey().generatedAlwaysAsIdentity(),   // not serial
  ownerId: text().notNull().references(() => appUser.id, { onDelete: 'cascade' }),
  title: text().notNull(),
  isArchived: boolean().notNull().default(false),
  createdAt: timestamp({ withTimezone: true, mode: 'date' }).notNull().defaultNow(),
}, (t) => [                                                 // array form; the object form is deprecated
  index('project_owner_idx').on(t.ownerId),                 // Postgres never indexes a foreign key for you
  index('project_created_idx').on(t.createdAt.desc()),
  uniqueIndex('project_owner_title_uq').on(t.ownerId, sql`lower(${t.title})`),
  check('project_title_len', sql`length(${t.title}) > 0`),
]);
```

- **No `server-only` in this file.** `drizzle-kit` loads it under Node, where `import 'server-only'` throws `This module
  cannot be imported from a Client Component module`. The import belongs in the client file, which only the app loads.
- **Implicit column names** with `casing: 'snake_case'` on the client and in `drizzle.config.ts`: `ownerId` becomes
  `owner_id`. Do not also pass the name as a first argument.
- **Identity keys**: `generatedAlwaysAsIdentity()`, never `serial`.
- **`timestamp({ withTimezone: true })`** always (`timestamptz`).
- **`$type<T>()` is a compile-time cast only**; validate input at the boundary.
- **`$defaultFn` runs in JavaScript; `.default()` is a SQL default.** Raw SQL inserts get only the latter.
- **`$onUpdate` fires only through Drizzle's `.update()`**; use a trigger if `updated_at` must be authoritative.
- **UUIDs**: `uuid().defaultRandom()` is v4 (random index locality). On PostgreSQL 18 use
  `uuid().default(sql\`uuidv7()\`)`.
- **Enums**: `pgEnum` values cannot be removed and new ones cannot be used in the same transaction; prefer `text()`
  plus `check()` for values that change.

## Relations in one file

Relations tell the relational query API how tables connect; they create no foreign keys.

```ts
// src/db/relations.ts
import { relations } from 'drizzle-orm';
import { appUser, project } from './schema';

export const appUserRelations = relations(appUser, ({ many }) => ({ projects: many(project) }));
export const projectRelations = relations(project, ({ one }) => ({
  owner: one(appUser, { fields: [project.ownerId], references: [appUser.id] }),
}));
```

Pass tables and relations together to `drizzle()` (`schema: { ...tables, ...relations }`, as in the client files
above), or `db.query` cannot see the relations. Do not `export * from './relations'` inside `schema.ts`: the two files
import each other, and drizzle-kit fails with "Cannot access 'appUser' before initialization".

## Validators in one file with drizzle-zod

drizzle-zod derives Zod schemas from tables, so input validation matches the columns.

```ts
// src/db/validators.ts
import { createInsertSchema, createSelectSchema, createUpdateSchema } from 'drizzle-zod';
import { project } from './schema';

export const insertProject = createInsertSchema(project, {
  title: (s) => s.min(1).max(200),        // the callback refines the derived schema
});
export const selectProject = createSelectSchema(project);
export const updateProject = createUpdateSchema(project);   // every field optional
```

A bare Zod schema (`{ title: z.string().min(1) }`) is still accepted, and it replaces the whole field, nullability
and optionality included: on drizzle-zod 0.8.3 a nullable `bio: z.string()` stopped accepting `null` and became
required. Use a callback when you mean to refine.

## Queries: db.query for trees, db.select for SQL shapes

`db.query.*` reads rows with their relations in one SQL statement; `db.select()` covers aggregates, window functions,
CTEs and set operations. Use both.

```ts
import { and, desc, eq } from 'drizzle-orm';

const rows = await db.query.project.findMany({
  where: (p, { eq, and }) => and(eq(p.ownerId, userId), eq(p.isArchived, false)),
  orderBy: (p, { desc }) => [desc(p.createdAt)],
  columns: { id: true, title: true },
  with: { owner: { columns: { email: true } } },
  limit: 20,
});

const total = await db.$count(project, eq(project.ownerId, userId));    // a number
```

Filter ownership in SQL (`eq(project.ownerId, userId)`), never by fetching and filtering in JavaScript.

## Transactions: use tx inside the callback

Inside `db.transaction`, every query must use `tx`. A query on the outer `db` runs on another connection, outside the
transaction, and silently breaks atomicity.

```ts
await db.transaction(async (tx) => {
  const [p] = await tx.insert(project).values({ ownerId: userId, title }).returning();
  await tx.insert(auditLog).values({ projectId: p.id, action: 'create' });
});
```

Keep transactions short and never call external services (payments, email, LLMs) inside them: the connection is
held the whole time.

Upserts, keyset pagination and the `sql` escape hatch: [references/queries.md](references/queries.md).

## drizzle-kit commands and which are safe in production

drizzle-kit has commands that write reviewable SQL and commands that change a database directly; only the first kind
belongs in a production workflow.

| Command | What it does | Production? |
|---|---|---|
| `drizzle-kit generate` | diffs the TypeScript schema against the last snapshot and writes a numbered `.sql` file (`0000_name.sql`; `migrations.prefix` defaults to `index` and also takes `timestamp`, `supabase`, `unix` and `none`); touches no database | yes: the reviewable artifact |
| `drizzle-kit migrate` | applies unapplied `.sql` files and records them in `drizzle.__drizzle_migrations` | yes: the only apply path |
| `drizzle-kit push` | introspects the live database and applies the diff at once; no file, no history | never: it can drop a column you removed from the schema |
| `drizzle-kit check` | checks the migration history for conflicts (two branches generating migrations) | run in CI on every pull request |
| `drizzle-kit pull` (alias of `introspect`) | live database to TypeScript schema | bootstrap an existing database only |
| `drizzle-kit export` | prints the full schema as SQL (diff against an empty database) | review and documentation |
| `drizzle-kit up` | upgrades old snapshot files to the current format; not "down" | maintenance only |
| `drizzle-kit studio` | browser UI on the database | development; never point it at production with a write role |

Using `push` and `generate` on the same database puts the snapshot out of sync with reality, and the next `generate`
emits wrong SQL. Pick one workflow per database (push for throwaway prototypes, generate and migrate for everything
else), and guard `push` so it cannot run in production ([references/migrations.md](references/migrations.md)).

## One drizzle.config.ts per database

Each database has its own config, schema folder and migrations folder.

```ts
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'postgresql',
  schema: './src/db/schema.ts',
  out: './drizzle',
  dbCredentials: { url: process.env.DATABASE_URL_DIRECT! },   // direct, not pooled
  migrations: { table: '__drizzle_migrations', schema: 'drizzle' },
  strict: true,       // asks before destructive statements (push)
  verbose: true,      // prints the SQL
  casing: 'snake_case',
});
```

**Two URLs.** The pooled URL is for the application at run time. The direct (unpooled) URL is for `migrate`, `push`,
`studio` and seeds: a transaction pooler hands each transaction to a different server connection, which breaks
session settings, advisory locks and multi-statement migrations.

**Two roles.** The application role gets DML only; the migration role owns the schema and runs DDL. An app that
cannot `DROP TABLE` cannot be tricked into dropping one.

## Shipping migrations safely

A production migration is a reviewed `.sql` file, applied by one CI job before the deploy. These rules cover most of
what goes wrong, and [references/migrations.md](references/migrations.md) has the scripts and the reasons.

- The migrator runs every pending file in one transaction, split at `--> statement-breakpoint`: keep those comments.
- Run migrations in CI on the direct URL as the migration role, never at app boot, and serialize them with a session
  advisory lock.
- Start each file with `SET lock_timeout`; it stays set for the rest of the migrator's session.
- Build indexes on big tables `CONCURRENTLY` in a CI step before the migrator, and use `IF NOT EXISTS` in the file.
- Read every generated statement: rewrite `RENAME COLUMN`, volatile defaults, `SET NOT NULL`, foreign keys and enum
  additions for a live table.
- Ship expand-only changes, and treat rollback as a forward fix: there are no down migrations.
- Test with PGlite running the real migrations, plus one integration test on a real server.

## Worked example: "add a status column to projects and filter by it"

A new filterable column touches the schema, a generated migration that must be made safe, CI and a query.

1. Schema: add the column, its check and its index to the `project` table:

```ts
status: text().notNull().default('active'),
// in the table's extra config array:
check('project_status', sql`${t.status} IN ('active', 'archived')`),
index('project_status_idx').on(t.status),
```

2. `npx drizzle-kit generate --name project_status` writes the SQL. Read it: `ADD COLUMN "status" text DEFAULT 'active'
   NOT NULL` is instant (constant default); `ADD CONSTRAINT ... CHECK` scans the table, so append `NOT VALID` and add a
   second migration with `VALIDATE CONSTRAINT`; the `CREATE INDEX` gets `IF NOT EXISTS`.
3. Put `SET lock_timeout = '3s';` and a `--> statement-breakpoint` at the top of the file.
4. CI: `drizzle-kit check`, then the concurrent index step on the direct URL, then `scripts/migrate.ts` under the
   advisory lock, then the deploy.
5. Query: `db.query.project.findMany({ where: (p, { and, eq }) => and(eq(p.ownerId, userId), eq(p.status, 'active')) })`,
   and a PGlite test that runs the real migrations and inserts a row with a bad status to prove the check rejects it.

## Verify a Drizzle schema and its migrations

These commands prove the schema, the snapshot and the generated SQL agree, on a scratch database before CI touches
production.

```bash
npx tsc --noEmit                       # the schema and queries compile
npx drizzle-kit check                  # no conflict between migration files
npx drizzle-kit generate               # prints "No schema changes" when the files match the schema
DATABASE_URL_DIRECT="$SCRATCH_URL" npx tsx scripts/migrate.ts      # the real files apply from empty
```

On the scratch database, `SELECT count(*) FROM drizzle.__drizzle_migrations` equals the number of files in `drizzle/`.
Then insert one row that must fail a `check()` to prove the constraint shipped.

## Checklist

Check these points before you call Drizzle code or a Drizzle migration done.

- [ ] `drizzle-orm` 0.45.x pinned (or the RC chosen on purpose); `drizzle-kit` in devDependencies only.
- [ ] The client matches the runtime: one pool per process on Node, one client per request on Workers.
- [ ] Identity keys, `timestamptz`, array-form indexes, an index on every foreign key.
- [ ] Relations in `relations.ts`; validators in `validators.ts` with callback refinements.
- [ ] Transactions use `tx` only; no network calls inside them; ownership filtered in SQL.
- [ ] `generate` produced the `.sql` file and a person read every statement; `drizzle-kit check` passes in CI.
- [ ] `SET lock_timeout` at the top; expand-only; no `RENAME COLUMN` and no `DROP` in the same deploy as the code change.
- [ ] Big-table indexes built `CONCURRENTLY` before the migration; the migration uses `IF NOT EXISTS`.
- [ ] Migrations applied by one CI job, on the direct URL, as the migration role, under an advisory lock; `push` never
      used on this database.
- [ ] Tests run the real migrations.

## Gotchas

These are the failures seen most often with Drizzle and Postgres, each with its cause and fix.

1. **`defineRelations is not a function` or not exported.** That API is in the 1.0 RC only; on 0.45 use
   `relations()` per table.
2. **"Cannot perform I/O on behalf of a different request" on Workers.** A module-scope client. Create it per request.
3. **Too many connections in development.** Hot reload created a new `Pool` on every save. Keep it on `globalThis`.
4. **A transaction is not atomic.** A query inside `db.transaction` used the outer `db`. Use `tx`.
5. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block`.** The migrator wraps all pending files in one
   transaction. Build the index in a separate step.
6. **The next `generate` produces nonsense.** Someone ran `push` on a database managed by `generate`/`migrate`; the
   snapshot no longer matches. Rebuild the snapshot from the real schema in a branch and review it.
7. **Migrations hang or fail through the pooler.** The URL points at PgBouncer, Supavisor or Hyperdrive. Use the
   direct URL.
8. **Two developers' migrations conflict.** Both branches generated from the same snapshot. `drizzle-kit check`
   catches it; regenerate on top of main.
9. **`drizzle-kit` failed with "Cannot access 'appUser' before initialization".** `schema.ts` re-exports
   `relations.ts`, which imports `schema.ts`. Keep them separate and merge them only in `drizzle({ schema })`.
10. **drizzle-zod refinements stopped type-checking.** `npm install typescript` now gives 7.0; in our test drizzle-zod
    0.8.3's refinement callbacks failed under TypeScript 7.0.2 and passed under 5.9.3. Pin TypeScript 5.9 until
    drizzle-zod supports 7.

## Anti-patterns with Drizzle

| Do not | Do this instead |
|---|---|
| `drizzle-kit push` on a database that matters | `generate`, review, `migrate` |
| run migrations at app boot | one CI job with an advisory lock |
| migrate through a pooler URL | the direct URL |
| `import 'server-only'` in `schema.ts` | import it in the client file |
| use the outer `db` inside `db.transaction` | `tx` for every query |
| pass user input to `sql.raw()` | bound values in the `sql` template |

## See also

- `postgres-schema-migrations`: safe DDL in any tool.
- `postgres-cloudflare-hyperdrive`: Workers through Hyperdrive.
- `postgres-node-typescript`: node-postgres, postgres.js and Kysely.
- `postgres-connection-pooling`: pooled and direct URLs.
- `postgres-testing-ci`: PGlite, Testcontainers and migration checks.
- `postgres-schema-design`: types, keys and constraints.

## Sources

- https://orm.drizzle.team/docs/kit-overview and https://orm.drizzle.team/docs/drizzle-config-file
- https://orm.drizzle.team/docs/zod
- https://github.com/drizzle-team/drizzle-orm (0.45.4 source)
- Run on drizzle-kit 0.31.11 and drizzle-zod 0.8.3: `generate`, `check`, the `server-only` failure, bare Zod schemas.
