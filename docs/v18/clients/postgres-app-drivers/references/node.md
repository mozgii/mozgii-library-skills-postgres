---
title: PostgreSQL from Node.js with node-postgres, postgres.js and Kysely
author: MOZGII, Inc.
lang: en
---

# PostgreSQL from Node.js with node-postgres, postgres.js and Kysely

This reference shows connection, queries, transactions and types for the two main Node.js drivers and the Kysely
query builder.

## Contents

The sections of this reference on postgreSQL from Node.js with node-postgres, postgres.js and Kysely:

1. node-postgres (pg) setup
2. postgres.js setup
3. Kysely type-safe query builder
4. Node.js gotchas

## node-postgres (pg) setup

node-postgres (`pg`, 8.23) is the most used Node driver and the one Cloudflare Hyperdrive and many ORMs build on.

```ts
import pg from 'pg';

pg.types.setTypeParser(1082, (v) => v);                 // date stays 'YYYY-MM-DD'
// pg.types.setTypeParser(20, (v) => BigInt(v));        // int8 as BigInt, if the code can handle it

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,           // postgresql://app_api@db.example:5432/app
  ssl: { rejectUnauthorized: true, ca: process.env.PG_CA_CERT },
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  statement_timeout: 30_000,
  application_name: 'app-api',
});
pool.on('error', (err) => console.error('idle client error', err));   // otherwise an idle error crashes the process

const { rows } = await pool.query<{ id: string; email: string }>(
  'SELECT id, email FROM app.customers WHERE id = ANY($1::bigint[])', [ids],
);
```

- `pool.query` takes any free client for one statement; use `pool.connect()` and `client.release()` for
  transactions.
- In current 8.x releases, `sslmode=prefer`, `require` and `verify-ca` in a connection string are treated as
  `verify-full` (with a warning that libpq semantics come in a later major); pass an explicit `ssl` object so the
  behaviour does not change under you.
- `pg-cursor` and `pg-query-stream` read large results without loading them all.

## postgres.js setup

postgres.js (`postgres`, 4.0) uses tagged templates, so every interpolation is a parameter. Version 4 lets the server
type parameters, so a value the query does not pin down needs a cast (`${date}::timestamptz`), and `sql.array()` is
gone: pass the array with a cast (`${ids}::int[]`).

```ts
import postgres from 'postgres';

export const sql = postgres(process.env.DATABASE_URL!, {
  max: 10,
  idle_timeout: 30,
  connect_timeout: 5,
  ssl: 'verify-full',
  connection: { application_name: 'app-api', statement_timeout: 30000 },
  // prepare: false,                      // only behind a pooler without prepared statement support
});

const users = await sql`SELECT id, email FROM app.customers WHERE email = ${email}`;
await sql.begin(async (tx) => {
  await tx`UPDATE app.accounts SET balance = balance - ${amount} WHERE id = ${from}`;
  await tx`UPDATE app.accounts SET balance = balance + ${amount} WHERE id = ${to}`;
});
const rows = await sql`SELECT * FROM app.orders WHERE status IN ${sql(['paid', 'shipped'])}`;   // list helper
```

`sql.unsafe(text)` runs a raw string without parameters: never pass user input to it.

## Kysely type-safe query builder

Kysely (0.29) builds SQL with full TypeScript types from a database interface; it runs on node-postgres.

```ts
import { Kysely, PostgresDialect, type Generated } from 'kysely';
import pg from 'pg';

interface DB {
  'app.customers': { id: Generated<string>; email: string; created_at: Generated<Date> };   // 'schema.table' keys
}

export const db = new Kysely<DB>({ dialect: new PostgresDialect({ pool: new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 }) }) });

const row = await db.selectFrom('app.customers').select(['id', 'email'])
  .where('email', '=', email).executeTakeFirst();

await db.transaction().execute(async (trx) => {
  await trx.insertInto('app.customers').values({ email }).onConflict((oc) => oc.column('email').doNothing()).execute();
});
```

Generate the `DB` interface from the live schema with `kysely-codegen` instead of writing it by hand.

## Node.js gotchas

These Node.js driver problems come up most often, each with its cause and fix.

1. **Unhandled `error` event on the pool crashes the process** when the server restarts. Attach `pool.on('error')`.
2. **`pool.query('BEGIN')` then `pool.query('...')`** runs on different clients: no transaction. Use one client.
3. **ESM import of pg**: `import pg from 'pg'` then `pg.Pool`; named imports work in recent versions but not all
   bundlers.
4. **Edge runtimes** (Vercel Edge, Cloudflare Workers) have no TCP sockets by default: use Hyperdrive on Workers
   (`postgres-cloudflare-hyperdrive`) or an HTTP driver such as `@neondatabase/serverless`.
