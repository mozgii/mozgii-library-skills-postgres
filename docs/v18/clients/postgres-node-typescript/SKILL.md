---
name: postgres-node-typescript
description: 'Builds Node.js and TypeScript data access on PostgreSQL in depth: a runnable node-postgres quickstart, Pool settings and their real defaults, type parsers for bigint, numeric, date and timestamptz, pg-cursor and pg-query-stream for large results, COPY with pg-copy-streams, LISTEN on a dedicated client, pipelining, postgres.js tagged templates, transactions, sql.unsafe and its TLS trap, Kysely with kysely-codegen and migrations, Prisma 7 with the pg adapter, TypedSQL and raw query safety, Neon, Bun and Deno. Use when writing Postgres code in Node, TypeScript, Bun or Deno, "bigint comes back as a string", streaming millions of rows, bulk loading from Node, or generating TypeScript types from the database.'
metadata:
  tags:
  - postgres
  - nodejs
  - typescript
  - node-postgres
  - postgres-js
  - kysely
  - prisma
  - bun
  - deno
---

# PostgreSQL from Node.js and TypeScript

Use `pg` (node-postgres) unless there is a reason not to: it is the base that Kysely, Prisma 7, Drizzle and Cloudflare
Hyperdrive build on. Pick postgres.js for tagged-template SQL with fewer allocations, Kysely when the team wants typed
SQL without an ORM, Prisma for schema-first CRUD. The cross-language choice and the shared rules (one pool,
parameters, retries on `40001` and `40P01`) are in `postgres-app-drivers`; Drizzle has its own skill,
`postgres-drizzle`. Detail: [Kysely and Prisma 7 in depth](references/kysely-prisma.md),
[serverless, Bun and Deno](references/serverless-bun-deno.md).

## Quickstart: connect, query and close with node-postgres

This quickstart creates a project, installs `pg`, and runs one parameterized query. Node.js 24 runs `.ts` files
directly by stripping types (erasable syntax only: no `enum`, no `namespace`), so no build step is needed to try it.

```bash
mkdir pg-quickstart && cd pg-quickstart
npm init -y && npm pkg set type=module
npm install pg@8.23.1
npm install -D @types/pg@8.23.1 @types/node typescript
```

The program below opens a pool, queries the server, and always closes the pool, even on error.

```ts
// main.ts
import pg from 'pg';

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  connectionTimeoutMillis: 5_000,
  idleTimeoutMillis: 30_000,
  application_name: 'quickstart',
});
pool.on('error', (err) => console.error('idle client error', err.message));

try {
  const { rows } = await pool.query<{ now: Date; version: string }>(
    'SELECT now() AS now, current_setting($1) AS version',
    ['server_version'],
  );
  console.log(rows[0]);
} finally {
  await pool.end();
}
```

Run it with the URL in the environment: on macOS and Linux
`DATABASE_URL=postgresql://app:secret@localhost:5432/app node main.ts`; in PowerShell on Windows
`$env:DATABASE_URL="postgresql://app:secret@localhost:5432/app"; node main.ts`. Type-check with `npx tsc --noEmit`
(tsconfig: `"module": "nodenext"`, `"allowImportingTsExtensions": true`, `"erasableSyntaxOnly": true`).

## Step 0: read the installed Node, driver and ORM versions

The installed versions decide the API, so read them before writing code.

```bash
node --version
npm ls pg postgres kysely prisma @prisma/client
```

Current in October 2026: `pg` 8.23.1, `pg-cursor` 2.22.1, `pg-query-stream` 4.17.1,
`pg-copy-streams` 7.0.0, `postgres` 4.0.0, `kysely` 0.29.7, `kysely-codegen` 0.20.0, Prisma 7.10.1 (npm's `latest` tag
points at an 8.0.0 release candidate, so pin the version), TypeScript 7.0.2, `@neondatabase/serverless` 1.2.0, Bun 1.4.4,
Deno 2.9.8.

## Choosing pg, postgres.js, Kysely or Prisma

Pick by how the team wants to write queries. Kysely and Prisma both run on `pg` here, so its pool settings apply.

| Team wants | Use | Why the others lose here |
|---|---|---|
| Plain SQL, the widest support, the base for everything else | `pg` | none is simpler; the others add an API on top |
| Tagged-template SQL with safe helpers | postgres.js | `pg` needs manual `$n` numbering and more code for bulk inserts |
| Typed SQL, no ORM, generated types | Kysely | raw drivers do not check column names at compile time |
| Schema-first CRUD and a managed client | Prisma 7 | query builders leave relations and migrations to you |

## node-postgres Pool settings and their defaults

A node-postgres `Pool` passes its config to every client it creates, so client options (`statement_timeout`,
`ssl`, `application_name`) go in the same object. Several defaults surprise people.

| Option | Default | Set it to |
|---|---|---|
| `max` | 10 | the pool share this process gets (`postgres-connection-pooling`) |
| `connectionTimeoutMillis` | 0, wait forever | 2,000 to 5,000 so a full pool fails fast |
| `idleTimeoutMillis` | 10,000 | 30,000 for servers; lower behind a pooler |
| `maxLifetimeSeconds` | 0, disabled | 1,800 to rotate connections through a load balancer or failover |
| `allowExitOnIdle` | false | true in scripts and tests so the process can exit |
| `statement_timeout` / `query_timeout` | none | server-side cap / client-side cap, in ms |
| `onConnect` | none | an async hook that runs once per new connection (`SET` a role or search_path) |
| `pipeline` | false | true to pipeline queries on a checked-out client |

`pool.query()` takes any idle client for one statement. A transaction needs `const c = await pool.connect()` and
`c.release()` in `finally`, with every statement on `c`.

## node-postgres type parsers for bigint, numeric, date and timestamptz

node-postgres type parsers are global to the process, keyed by type OID, and must be set before the first query. The
defaults: `int8` and `numeric` come back as strings, `date` as a `Date` at local midnight, `timestamptz` as a `Date`.

```ts
import pg from 'pg';

pg.types.setTypeParser(pg.types.builtins.INT8, (v) => BigInt(v));   // 20: bigint as BigInt
pg.types.setTypeParser(pg.types.builtins.DATE, (v) => v);            // 1082: date stays 'YYYY-MM-DD'
// NUMERIC (1700) stays a string: pass it to a decimal library, never to parseFloat.
```

- `BigInt` does not survive `JSON.stringify`; convert at the API edge, or keep ids as strings.
- `count(*)` is `bigint`: with the parser above it becomes `10000n`.
- A per-query override exists: `pool.query({ text, values, types: { getTypeParser } })`.
- A JS array sent as a parameter becomes a Postgres array; for a `jsonb` parameter pass `JSON.stringify(value)`.

## Streaming large results with pg-cursor and pg-query-stream

A large `SELECT` through `pool.query` loads every row into memory. `pg-cursor` reads in batches on one checked-out
client; `pg-query-stream` wraps the same cursor as a Node `Readable` with backpressure.

```ts
import Cursor from 'pg-cursor';
import QueryStream from 'pg-query-stream';

const client = await pool.connect();
try {
  const cursor = client.query(new Cursor('SELECT id FROM events WHERE kind = $1 ORDER BY id', ['click']));
  for (let rows = await cursor.read(1000); rows.length > 0; rows = await cursor.read(1000)) {
    // process 1,000 rows
  }
  await cursor.close();

  for await (const row of client.query(new QueryStream('SELECT id, amount FROM events', [], { batchSize: 500 }))) {
    // one row at a time
  }
} finally {
  client.release();
}
```

The cursor lives in the client's session, so it does not survive a transaction-mode pooler between reads unless it
runs inside one transaction. Install `@types/pg-cursor` for TypeScript.

## COPY with pg-copy-streams for bulk load and export

`COPY` is the fastest way to move rows, and `pg-copy-streams` exposes it as Node streams. `pipeline` from
`node:stream/promises` propagates errors and ends the stream.

```ts
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { createWriteStream } from 'node:fs';
import { from as copyFrom, to as copyTo } from 'pg-copy-streams';

const client = await pool.connect();
try {
  const lines = rows.map((r) => `${r.kind},${r.amount},${r.day}\n`);   // escape per CSV rules for real data
  await pipeline(Readable.from(lines),
    client.query(copyFrom('COPY events (kind, amount, happened) FROM STDIN WITH (FORMAT csv)')));
  await pipeline(client.query(copyTo('COPY (SELECT * FROM events) TO STDOUT WITH (FORMAT csv, HEADER)')),
    createWriteStream('events.csv'));
} finally {
  client.release();
}
```

One bad row aborts the whole `COPY`. For large loads into live tables, load into a staging table and merge
(`postgres-sql-patterns`).

## LISTEN and NOTIFY from node-postgres

`LISTEN` belongs to one session, so it needs a dedicated `pg.Client`, not `pool.query` (the pool may hand the next
query to another connection and close idle ones). Reconnect and re-`LISTEN` on `error` or `end`.

```ts
const listener = new pg.Client({ connectionString: process.env.DATABASE_URL });
await listener.connect();
listener.on('notification', (msg) => console.log(msg.channel, msg.payload));
await listener.query('LISTEN job_ready');
await pool.query('SELECT pg_notify($1, $2)', ['job_ready', JSON.stringify({ id: 42 })]);
```

`NOTIFY` is delivered at commit, payloads are limited to under 8000 bytes, and a listener behind a transaction-mode
pooler never hears anything: connect it directly to Postgres.

## postgres.js tagged templates and helpers

postgres.js turns every `${value}` in a tagged template into a bind parameter, and `sql(...)` helpers build
identifiers, value lists and multi-row inserts safely.

```ts
import postgres from 'postgres';

const sql = postgres(process.env.DATABASE_URL!, {
  max: 10, idle_timeout: 30, connect_timeout: 5, max_lifetime: 60 * 30,   // seconds
  types: { bigint: postgres.BigInt },
  transform: postgres.camel,                     // owner_name <-> ownerName
  connection: { application_name: 'app-api', statement_timeout: 30_000 },
});

await sql`INSERT INTO accounts ${sql(people, 'ownerName', 'balanceCents')}`;          // many rows, one statement
const rows = await sql`SELECT * FROM accounts WHERE owner_name IN ${sql(names)}`;     // value list
const sorted = await sql`SELECT * FROM accounts ORDER BY ${sql(allowed[key])}`;      // identifier from an allowlist
```

`sql.begin(fn)` reserves one connection and hands the callback a scoped `sql`; `tx.savepoint(fn)` nests. Errors are
`postgres.PostgresError` with `code` (SQLSTATE) and `constraint_name`.

## Upgrading postgres.js from 3 to 4

postgres.js 4.0.0 (29 October 2026) rewrote the pool, connection and protocol layers and keeps most of the API, but
it changes how parameters are typed, so read this before bumping the version. Supported runtimes are Bun, Cloudflare
Workers and Node.js from version 20, as an ES module; Deno goes through its Node.js compatibility.

| Change in 4 | What you see | Fix |
|---|---|---|
| The server types every parameter (`infer: false`) | `function date_trunc(unknown, unknown) is not unique` where a query does not fix the type | cast it: `${date}::timestamptz`, or `infer: true` to keep v3 behaviour |
| A `Date` is no longer sent as `timestamptz` | outside UTC, a `Date` against a `timestamp` or `date` column is taken as UTC, and near midnight a `date` can be a day off | use `timestamptz`, or `infer: true` while migrating |
| `sql.array()` removed | throws `ARRAY_REMOVED` | pass the array with a cast: `${ids}::int[]` |
| A manual `begin` outside `sql.begin` or a reserved connection | rejects with `UNSAFE_TRANSACTION`, rolled back | use `sql.begin(fn)` |
| A transaction the server rolled back | `sql.begin` rejects with `TRANSACTION_ROLLED_BACK` (v3 treated that as success) | handle the rejection |
| A failed build inside a transaction | later queries fail with `25P02` (v3 skipped the query and committed) | let the error abort the transaction |
| `53300` too many connections | retried until `connect_timeout`, not rejected at once | size `connect_timeout` for it |

New options worth setting: `queue_timeout` (how long a query queues for a connection, in seconds), `channel_binding`, and
`.signal(abortSignal)` on a query. Nested `sql.begin` is a savepoint. 4.0.0 also fixes two security bugs: a NUL
character in `database` or `user` could add startup parameters, and a column named `__proto__` set a row's prototype.
Its notes mark both as affecting v3, and no 3.x release followed 3.4.9 as of 30 October 2026, so an app that puts
untrusted input in connection options should move to 4. The example above ran on 4.0.0 and PostgreSQL 18.6.

## postgres.js sql.unsafe, prepared statements and TLS

postgres.js `sql.unsafe(text, params)` sends a raw string: the text is never escaped, so only trusted, constant SQL
goes in it, and user values go in `params`. It also turns prepared statements off unless `{ prepare: true }`.

- `prepare: true` (the default) names statements per connection. Behind PgBouncer in transaction mode before 1.21,
  or with `max_prepared_statements = 0`, set `prepare: false`.
- TLS trap: postgres.js treats `ssl: 'require'`, `'prefer'` and `sslmode=require` as encrypt without checking the
  certificate. Use `ssl: 'verify-full'` or a `tls.connect` options object with `ca`.
- `sql.listen(channel, fn)` opens its own connection and re-listens after reconnects.
- COPY: ``await sql`COPY t FROM STDIN`.writable()`` and ``.readable()`` return Node streams.
- `.cursor(1000)` iterates batches with `for await`.

## Kysely typed query builder with kysely-codegen

Kysely builds SQL from a `DB` interface, so a typo in a column is a compile error. Generate the interface from the
live schema with `kysely-codegen` (it reads `DATABASE_URL`) and commit the output.

```bash
npm install kysely@0.29.7 pg@8.23.1
npm install -D kysely-codegen@0.20.0
npx kysely-codegen --dialect postgres --include-pattern 'shop.*' --out-file src/db.d.ts
npx kysely-codegen --dialect postgres --include-pattern 'shop.*' --out-file src/db.d.ts --verify   # CI drift check
```

The generated types follow the driver: `bigint` columns are `Int8` (read as `string`), `numeric` is `string`. Change
both together (`--numeric-parser`, `--type-mapping`) when you install type parsers. Migrations import from
`kysely/migration` in 0.29: [Kysely and Prisma 7 in depth](references/kysely-prisma.md).

## Prisma 7 with PostgreSQL: adapter, raw SQL and errors

Prisma 7 always runs through a driver adapter (`@prisma/adapter-pg` uses node-postgres), so the pool settings are
`pg` settings with `pg` defaults: no connection timeout and a 10 s idle timeout. Install, schema and migrate basics are
in `postgres-app-drivers` (its Prisma 7 reference).

```ts
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient, Prisma } from './generated/prisma/client.ts';

const adapter = new PrismaPg({ connectionString: process.env.DATABASE_URL, max: 10,
  connectionTimeoutMillis: 5_000, idleTimeoutMillis: 30_000 });
export const prisma = new PrismaClient({ adapter });

const rows = await prisma.$queryRaw<{ email: string }[]>`
  SELECT email FROM customers WHERE id IN (${Prisma.join(ids)})`;     // parameters, safe
```

- `$queryRawUnsafe` and `$executeRawUnsafe` take a string: injection-prone. Never build it from input.
- `Prisma.raw()` inserts text unescaped, even inside `$queryRaw`.
- Unique violation is `P2002`; `Serializable` write conflicts are `P2034`.
- In October 2026 npm `latest` for `prisma` is an 8.0.0 release candidate; the Prisma docs name the 7 line
  `prisma@prev`. Pin `prisma@7.10.1` and `@prisma/client@7.10.1`.

## TypeScript types from the database

Types that come from the database stay true after a migration; hand-written interfaces drift. Choose by tool.

| Tool | Command | Output |
|---|---|---|
| Kysely | `kysely-codegen --out-file src/db.d.ts` | the `DB` interface |
| Prisma | `prisma generate` (`--sql` for TypedSQL) | client and per-query result types |
| Drizzle | `drizzle-kit pull` | a schema file (`postgres-drizzle`) |
| plain `pg` | a `rows` generic on `pool.query<T>()` | nothing checked: validate at the edge (zod) |

Run the generator in CI against a database migrated from scratch, and fail the build when the output differs.

## Verify Node.js database code

Type-check first, run the quickstart, then read from the server what the pool really did. The query ran on 18.6.

```bash
npx tsc --noEmit
npx kysely-codegen --dialect postgres --include-pattern 'shop.*' --out-file src/db.d.ts --verify   # CI drift check
```

```sql
SELECT a.application_name, a.state, s.ssl, count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid)
WHERE a.application_name = 'quickstart' GROUP BY 1, 2, 3;     -- total at or under max; ssl true off localhost
```

Restart Postgres during a test run: the process must log the idle client error and carry on, not exit. Under load with
a full pool, a request must fail after `connectionTimeoutMillis`, not hang.

## Gotchas

These are the Node.js failures seen most often, each with its symptom, cause and fix.

1. **The process exits with `Connection terminated unexpectedly` when Postgres restarts.** An idle pool client
   emitted `error` with no listener. Add `pool.on('error', ...)` once at startup.
2. **Requests hang for minutes under load.** `connectionTimeoutMillis` is 0 by default (also under Prisma 7). Set it.
3. **`BEGIN` and the next query ran on different connections.** `pool.query('BEGIN')` was used. Check out a client.
4. **Dates shift by one day.** The default `date` parser makes a local-midnight `Date`. Parse OID 1082 as a string.
5. **A TLS connection is encrypted but not verified.** postgres.js `ssl: 'require'` skips verification; node-postgres
   8.x treats `sslmode=require` as `verify-full` with a warning. Be explicit in both.
6. **`prepared statement "s0" already exists` or `does not exist`.** A transaction-mode pooler without prepared
   statement support. Use PgBouncer 1.21 or later with `max_prepared_statements`, or `prepare: false`.
7. **`does not provide an export named 'FileMigrationProvider'`.** Kysely 0.29 moved it to `kysely/migration`.
8. **`function date_trunc(unknown, unknown) is not unique` after upgrading postgres.js.** Version 4 no longer types
   a `Date` from JavaScript. Cast the parameter: `${date}::timestamptz`.
9. **Memory climbs on a big export.** `pool.query` buffers all rows. Use a cursor, a stream, or `COPY TO STDOUT`.

## Anti-patterns in Node.js data access

These pass in development and fail under load or in production.

| Do not | Do instead |
|---|---|
| Run `pool.query('BEGIN')` | Check out one client, or use `sql.begin`, `trx` or `tx` |
| Leave `connectionTimeoutMillis` at 0 | Set 2,000 to 5,000 so a full pool fails fast |
| Parse `numeric` with `parseFloat` | Keep the string and use a decimal library |
| Pass user input to `sql.unsafe`, `$queryRawUnsafe` or `Prisma.raw` | Use tagged templates or `$n` parameters |
| Trust `ssl: 'require'` in postgres.js | Use `ssl: 'verify-full'` or an options object with `ca` |
| Create a new `Pool` per request | Create one pool per process at startup |

## Checklist

Check these points before calling Node.js database code done.

- [ ] One pool per process with `max`, `connectionTimeoutMillis` and `idleTimeoutMillis` set; `pool.on('error')`.
- [ ] Transactions run on one checked-out client (or `sql.begin`, `trx`, `tx`) and retry `40001` and `40P01`.
- [ ] Type parsers for `int8`, `numeric` and `date` chosen on purpose and matched in generated types.
- [ ] No `sql.unsafe`, `$queryRawUnsafe` or `Prisma.raw` with user input.
- [ ] TLS verifies the certificate in every driver's own terms.
- [ ] Large reads stream; bulk writes use `COPY` or multi-row inserts.
- [ ] Database types are generated and checked for drift in CI.

## See also

Related skills in this library, each one works on its own:

- `postgres-app-drivers`: the cross-language choice and shared rules.
- `postgres-drizzle`: Drizzle ORM in depth.
- `postgres-cloudflare-hyperdrive`: Workers and Hyperdrive.
- `postgres-connection-pooling`: pool budgets and PgBouncer.
- `postgres-transactions-locking`: retries on `40001` and `40P01`.
- `postgres-bulk-load-etl`: staging tables and large loads.

## Sources

- https://node-postgres.com/apis/pool, /apis/client, /apis/cursor, /features/types, /features/ssl, /features/pipelining
- https://github.com/porsager/postgres (README: options, transactions, COPY, listen, prepared statements)
- https://kysely.dev/docs/migrations and `npx kysely-codegen --help` (0.20.0)
- https://www.prisma.io/docs/orm/v7/prisma-client/using-raw-sql/raw-queries, /typedsql, /setup-and-configuration/databases-connections/connection-pool, /pgbouncer
- https://nodejs.org/api/typescript.html (Node 24 type stripping)
- https://www.postgresql.org/docs/18/sql-copy.html, /sql-notify.html
- npm registry dist-tags for every package named, read 2026-10-28
