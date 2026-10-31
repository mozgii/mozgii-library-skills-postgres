---
title: PostgreSQL from serverless JavaScript, Bun and Deno
author: MOZGII, Inc.
lang: en
---

# PostgreSQL from serverless JavaScript, Bun and Deno

This reference covers JavaScript runtimes other than a long-running Node.js server: serverless and edge functions,
Bun's built-in SQL client, and Deno with npm drivers. Pooling theory for these targets is in
`postgres-connection-pooling`; Cloudflare Workers are in `postgres-cloudflare-hyperdrive`.

## Contents

The sections of this reference on serverless JavaScript, Bun and Deno:

1. Serverless functions and connection counts
2. Neon serverless driver over HTTP and WebSockets
3. Vercel Fluid compute and attachDatabasePool
4. Cloudflare Workers through Hyperdrive
5. Bun.SQL, Bun's built-in PostgreSQL client
6. Deno with npm:pg or npm:postgres

## Serverless functions and connection counts

A serverless function instance that opens its own pool multiplies connections by the number of instances. Keep the
in-function pool at `max: 1` to `5`, point the runtime URL at a pooler (PgBouncer, the provider's pooled endpoint,
Hyperdrive), and run migrations on the direct URL. Create the pool at module scope only where the platform reuses
instances between requests (AWS Lambda, Vercel Fluid compute); on edge runtimes create it inside the handler.

## Neon serverless driver over HTTP and WebSockets

The Neon serverless driver (`@neondatabase/serverless` 1.2.0) has two modes. `neon(url)` sends each query as an HTTPS
request: fast for one-shot queries, no sessions, no interactive transactions. `Pool` and `Client` speak the
node-postgres API over WebSockets and support transactions.

```ts
import { neon, Pool } from '@neondatabase/serverless';

const sql = neon(process.env.DATABASE_URL!);
const [post] = await sql`SELECT * FROM posts WHERE id = ${postId}`;           // parameter, safe
const [a, b] = await sql.transaction([sql`SELECT 1`, sql`SELECT 2`]);        // non-interactive transaction

export default async function handler(req: Request) {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });     // inside the handler on edge runtimes
  try { /* pool.connect(), BEGIN ... COMMIT */ } finally { await pool.end(); }
}
```

On Node.js 21 and earlier, `Pool` needs a WebSocket constructor (`neonConfig.webSocketConstructor = ws`). This
block follows the driver's README and was not run here: it needs a Neon project.

## Vercel Fluid compute and attachDatabasePool

On Vercel Fluid compute an instance serves many requests and may be suspended between them. `attachDatabasePool(pool)`
from `@vercel/functions` (3.10.4) releases idle pool clients before suspension; call it right after creating a module
scope `pg.Pool`. The block follows Vercel's function API reference and was not run here: it needs a Vercel
deployment.

```ts
import { Pool } from 'pg';
import { attachDatabasePool } from '@vercel/functions';

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5, idleTimeoutMillis: 5_000 });
attachDatabasePool(pool);
```

## Cloudflare Workers through Hyperdrive

Cloudflare Workers reach PostgreSQL through Hyperdrive with node-postgres created per request. The binding, caching,
local development and the "different request" error are covered in `postgres-cloudflare-hyperdrive`. postgres.js
lowers its default `max` to 3 when it detects Workers.

## Bun.SQL, Bun's built-in PostgreSQL client

Bun 1.4 ships `Bun.SQL`, a tagged-template client with pooling, transactions, `LISTEN`/`NOTIFY` and `COPY` as web
streams. It reads `DATABASE_URL` (then `POSTGRES_URL`, `PGURL`, `PG_URL`) when no URL is passed. `bigint`
(`int8`) values come back as strings unless `bigint: true`.

```ts
import { SQL } from 'bun';

const sql = new SQL(process.env.DATABASE_URL!, { max: 10, idleTimeout: 30, connectionTimeout: 5, bigint: true });
const [row] = await sql`SELECT 9007199254740993::int8 AS big, ${name}::text AS name`;   // big: 9007199254740993n
await sql.begin(async (tx) => { await tx`UPDATE accounts SET balance = balance - ${n} WHERE id = ${id}`; });
await sql.close();
```

`idleTimeout` defaults to 0 (off) and `connectionTimeout` to 30 seconds. `pg`, `postgres` and Kysely also run under
Bun from npm.

## Deno with npm:pg or npm:postgres

Deno 2 runs npm drivers through `npm:` specifiers; it needs network and environment permissions.

```ts
// main.ts, run with: deno run --allow-net --allow-env main.ts
import pg from 'npm:pg@8.23.1';

const pool = new pg.Pool({ connectionString: Deno.env.get('DATABASE_URL'), max: 5 });
const { rows } = await pool.query('SELECT $1::text AS name', ['ann']);
await pool.end();
```

Add `--allow-read` when the driver reads certificate files or a `.pgpass`. On Deno Deploy, use a pooled URL as for any
serverless function.
