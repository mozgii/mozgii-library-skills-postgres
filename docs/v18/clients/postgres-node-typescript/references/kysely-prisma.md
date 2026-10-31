---
title: Kysely and Prisma 7 in depth with PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Kysely and Prisma 7 in depth with PostgreSQL

This reference shows Kysely migrations and typed queries, and the Prisma 7 parts that go beyond the basics in
`postgres-app-drivers`: TypedSQL, the generated SQL to review, and the pool settings of the pg adapter. Every block
here ran against PostgreSQL 18.6 with Kysely 0.29.7, kysely-codegen 0.20.0 and Prisma 7.10.1.

## Contents

The sections of this reference on Kysely and Prisma 7:

1. Kysely migrations with Migrator and FileMigrationProvider
2. Kysely queries: upsert, ANY with an array, transactions, compile
3. Prisma 7 project files for PostgreSQL
4. Prisma TypedSQL: typed results from plain SQL files
5. Prisma Migrate output to review on PostgreSQL
6. Prisma 7 pg adapter pool settings

## Kysely migrations with Migrator and FileMigrationProvider

Kysely migrations are TypeScript files that export `up` and `down`, taking `Kysely<any>` (never the typed `DB`,
which changes as migrations run). In 0.29 the migrator lives in `kysely/migration`.

```ts
// migrations/2026_10_28_001_customers.ts
import { type Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await db.schema.createSchema('shop').ifNotExists().execute();
  await db.schema
    .createTable('shop.customers')
    .addColumn('id', 'bigint', (c) => c.primaryKey().generatedAlwaysAsIdentity())
    .addColumn('email', 'text', (c) => c.notNull().unique())
    .addColumn('credit', 'numeric(12, 2)', (c) => c.notNull().defaultTo(0))
    .addColumn('created_at', 'timestamptz', (c) => c.notNull().defaultTo(sql`now()`))
    .execute();
}

export async function down(db: Kysely<any>): Promise<void> {
  await db.schema.dropTable('shop.customers').execute();
}
```

The runner below applies pending migrations and exits non-zero on failure, for a CI step on the direct (unpooled) URL.

```ts
// migrate.ts
import { promises as fs } from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { Kysely, PostgresDialect } from 'kysely';
import { FileMigrationProvider, Migrator } from 'kysely/migration';

const db = new Kysely<unknown>({
  dialect: new PostgresDialect({ pool: new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 1 }) }),
});
const migrator = new Migrator({
  db,
  provider: new FileMigrationProvider({ fs, path, migrationFolder: path.join(import.meta.dirname, 'migrations') }),
});
const { error, results } = await migrator.migrateToLatest();
for (const r of results ?? []) console.log(r.status, r.migrationName);
await db.destroy();
if (error) { console.error(error); process.exit(1); }
```

- File names sort as text: use a date prefix so order is stable.
- Kysely records applied migrations in `kysely_migration` and takes a lock table (`kysely_migration_lock`), so two
  runners do not apply the same file twice.
- Long-running DDL on big tables follows `postgres-schema-migrations` (`lock_timeout`, `CONCURRENTLY` outside a
  transaction).

## Kysely queries: upsert, ANY with an array, transactions, compile

Kysely query methods map one to one to SQL. This block upserts, filters by an array, and runs a serializable
transaction on the transaction handle `trx`.

```ts
import pg from 'pg';
import { Kysely, PostgresDialect, sql } from 'kysely';
import type { DB } from './src/db.d.ts';

export const db = new Kysely<DB>({
  dialect: new PostgresDialect({ pool: new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 }) }),
});

await db.insertInto('shop.customers')
  .values({ email, credit: '10.00' })
  .onConflict((oc) => oc.column('email').doUpdateSet({ credit: (eb) => eb.ref('excluded.credit') }))
  .execute();

const list = await db.selectFrom('shop.customers').select('email')
  .where('id', '=', sql<string>`any(${ids}::bigint[])`).execute();

await db.transaction().setIsolationLevel('serializable').execute(async (trx) => {
  await trx.updateTable('shop.customers').set({ credit: sql`credit + 5` }).where('id', '=', id).execute();
});

const { sql: text, parameters } = db.selectFrom('shop.customers').selectAll().where('email', '=', email).compile();
```

`compile()` returns the SQL and parameters without running them: log it, or test it. `numeric` values travel as
strings both ways, which keeps money exact.

## Prisma 7 project files for PostgreSQL

A Prisma 7 project has `prisma.config.ts` (CLI connection), `prisma/schema.prisma` (models, no URL), and the client
generated into the source tree. The CLI uses the direct URL; the app uses the pooled one through the adapter.

```bash
npm install @prisma/client@7.10.1 @prisma/adapter-pg@7.10.1 pg dotenv
npm install -D prisma@7.10.1
npx prisma migrate dev --name init       # development database only
npx prisma generate --sql                # Prisma 7: migrate dev does not generate
```

The generated client is TypeScript (`src/generated/prisma/client.ts`); Node 24 can import it directly, and `tsx` or
`tsc` work as usual.

## Prisma TypedSQL: typed results from plain SQL files

Prisma TypedSQL turns each `.sql` file in `prisma/sql/` into a typed function. It is a preview feature in Prisma 7
(`previewFeatures = ["typedSql"]` in the generator) and needs a live database at `prisma generate --sql` time.

```sql
-- prisma/sql/ordersByCustomer.sql
-- @param {BigInt} $1:customerId
SELECT id, total_cents FROM orders WHERE customer_id = $1 ORDER BY id
```

The call below runs it with a bound parameter and returns `{ id: bigint; total_cents: bigint }[]`.

```ts
import { ordersByCustomer } from './src/generated/prisma/sql.ts';
const rows = await prisma.$queryRawTyped(ordersByCustomer(customerId));
```

Use TypedSQL for reports, window functions and CTEs that the client API cannot express; arrays go through
`= ANY($1)`.

## Prisma Migrate output to review on PostgreSQL

Prisma Migrate writes SQL you should read before it reaches production. On PostgreSQL 18 with Prisma 7.10.1:

| Schema | Generated SQL | Consider |
|---|---|---|
| `BigInt @id @default(autoincrement())` | `BIGSERIAL` | fine; identity columns need hand-edited SQL |
| `DateTime` without `@db.Timestamptz(6)` | `TIMESTAMP(3)` without time zone | add `@db.Timestamptz(6)` |
| `Decimal @db.Decimal(12, 2)` | `DECIMAL(12,2)` | read as `Prisma.Decimal`, exact |
| `@@index([customerId])` | `CREATE INDEX` without `CONCURRENTLY` | for big tables use `--create-only` and edit |
| a relation | `ON DELETE RESTRICT ON UPDATE CASCADE` | set `onDelete` on purpose |

Raw query results map types too: `numeric` becomes `Prisma.Decimal`, `bigint` and `count(*)` become `bigint`.

## Prisma 7 pg adapter pool settings

The `@prisma/adapter-pg` adapter takes node-postgres `Pool` options, so its defaults are node-postgres defaults, not
Prisma 6 ones.

| Behaviour | Prisma 6 URL parameter (default) | Prisma 7 pg field (default) |
|---|---|---|
| pool size | `connection_limit` (CPUs x 2 + 1) | `max` (10) |
| wait for a connection | `pool_timeout` (10 s) | `connectionTimeoutMillis` (0, forever) |
| idle close | `max_idle_connection_lifetime` (300 s) | `idleTimeoutMillis` (10 s) |
| lifetime | `max_connection_lifetime` (0) | `maxLifetimeSeconds` (0) |

A non-default schema goes in the second argument: `new PrismaPg({ connectionString }, { schema: 'shop' })`. With
PgBouncer 1.21 or later and `max_prepared_statements` above 0, do not add `pgbouncer=true`; run Prisma Migrate on the
direct URL in `prisma.config.ts`.
