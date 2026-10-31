---
name: postgres-cloudflare-hyperdrive
description: 'Connects Cloudflare Workers to PostgreSQL through Hyperdrive, with local development on the same code: a per-request node-postgres client, why a module-scope client throws "Cannot perform I/O on behalf of a different request", which drivers work, query caching and a cache-disabled binding for fresh reads, what transaction pooling breaks, limits, and migrations on the direct URL. Use for any Workers database code, Hyperdrive setup, or Next.js on Workers data access.'
metadata:
  tags:
  - postgres
  - cloudflare
  - hyperdrive
  - workers
  - node-postgres
  - drizzle
  - serverless
  - connection-pooling
---

# Cloudflare Hyperdrive with PostgreSQL

Production reaches PostgreSQL through Cloudflare Hyperdrive; local development reaches a local PostgreSQL through
the same binding and the same code, with no `if (dev)` branch in the data layer. Facts here were checked against
Cloudflare's documentation in October 2026; read the current pages before relying on limits.

## Step 0: read Wrangler, the driver and the configurations

The minimum driver versions and the compatibility flags decide whether a Worker connects at all, so read them first.

```bash
npx wrangler --version
npm ls pg postgres drizzle-orm kysely 2>/dev/null
npx wrangler hyperdrive list
grep -nE 'nodejs_compat|compatibility_date|hyperdrive' wrangler.jsonc wrangler.toml 2>/dev/null
```

## Choose how a Worker reaches PostgreSQL

Hyperdrive is the default from Workers; the alternatives fit narrower cases.

| Need | Use | Why the others lose |
|---|---|---|
| any TCP-reachable PostgreSQL from Workers | Hyperdrive with node-postgres | a direct TCP connection pays the full handshake per request and has no pool |
| Neon only, one-shot queries over HTTP | `@neondatabase/serverless` | it bypasses Hyperdrive, so no shared pool or cache |
| Postgres.js as the driver | `postgres@3.4.5` or later (Cloudflare's stated minimum; its page does not mention 4.x), with `prepare` left on | fine alone, but Drizzle with Postgres.js over Hyperdrive is not supported |
| Drizzle or Kysely | node-postgres underneath | they sit on `pg`; nothing else changes |
| migrations, `LISTEN`, session advisory locks | a direct connection from CI or a service | a transaction pooler cannot hold session state |

## What Hyperdrive is

Hyperdrive sits between a Worker and an existing PostgreSQL database. It keeps warm connection pools near the
database and can cache read queries, so a Worker that creates a fresh client per request does not pay the TCP,
TLS and authentication handshake to the origin each time. It is a pooler in transaction mode, not a database.

Code always reads `env.HYPERDRIVE.connectionString`; only what it resolves to changes:

| Run | Resolves to |
|---|---|
| production (`wrangler deploy`) | the Hyperdrive pool in front of the production database |
| `wrangler dev` (or `next dev` with the Cloudflare adapter) | the local connection string, direct to your local Postgres |
| `wrangler dev --remote` | the real Hyperdrive configuration, with pooling and caching; writes hit that database |

## Creating a Hyperdrive configuration and binding

A Hyperdrive configuration stores the origin connection; the Worker gets it through a binding.

```bash
npx wrangler hyperdrive create acme-db --connection-string="postgres://<user>:<password>@db.acme.example:5432/app"
```

```jsonc
// wrangler.jsonc
{
  "compatibility_flags": ["nodejs_compat"],          // required for database drivers
  "compatibility_date": "2026-10-28",                // set to the current date when you create the Worker
  "hyperdrive": [
    { "binding": "HYPERDRIVE", "id": "<hyperdrive-config-id>" }
  ]
}
```

Use a database role for Hyperdrive with only the rights the app needs, and TLS to the origin.

## Local development binding

For local development, give the binding a local connection string through an environment variable named after the
binding: `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_<BINDING_NAME>`.

```bash
export CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="postgres://app_dev:<local password>@localhost:5432/app_dev"
npx wrangler dev
```

`localConnectionString` in the binding object of `wrangler.jsonc` works too, but keeps the credential in a file;
when both are set, the environment variable wins.

With a local connection string, Hyperdrive's pooling and caching do not run: the Worker talks to Postgres directly.
Before shipping anything that depends on latency or caching, run once with `wrangler dev --remote` against a
non-production configuration.

## The client: node-postgres, created per request

Create a new client inside the request handler. Hyperdrive keeps the pool, so creating a client is cheap. A client at
module scope is reused across requests and fails with "Cannot perform I/O on behalf of a different request".

```ts
import { Client } from 'pg';

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
    await client.connect();
    try {
      const { rows } = await client.query('SELECT id, title FROM app.posts ORDER BY id DESC LIMIT 20');
      return Response.json(rows);
    } finally {
      ctx.waitUntil(client.end());          // close after the response is sent
    }
  },
} satisfies ExportedHandler<Env>;
```

- Use `pg` 8.16.3 or later. Cloudflare documents named prepared statements as supported for node-postgres and
  postgres.js; leave prepared statements on.
- Postgres.js 4.0.0 is the current release, but Cloudflare's driver page states `postgres@3.4.5` and does not mention
  version 4, so treat 4.x over Hyperdrive as untested and try it in staging first.
- Drizzle: `drizzle({ client })` from `drizzle-orm/node-postgres` on the per-request `Client`. Pair it with `pg`:
  Cloudflare's Drizzle guide lists Drizzle on Postgres.js through Hyperdrive as a known issue with no support yet.
- Do not use `@neondatabase/serverless` or `drizzle-orm/neon-*` here: they speak HTTP or WebSocket to Neon and bypass
  Hyperdrive entirely.
- Do not hoist a prepared statement or a query object to module scope: the connection it was prepared on is gone in
  the next request.

For Next.js on Workers (OpenNext), wrap a per-request `Pool` in React `cache()` so one request shares it. A cached
function has no place to call `client.end()`, so set `maxUses: 1`, the form OpenNext documents: `pg` closes each
connection as soon as it is released, after one query or one transaction (tested with `pg` 8.23.1: 0 connections left).

```ts
import { cache } from 'react';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import { Pool } from 'pg';

export const getPool = cache(async () => {
  const { env } = await getCloudflareContext({ async: true });
  return new Pool({ connectionString: env.HYPERDRIVE.connectionString, maxUses: 1 });
});
// usage: const { rows } = await (await getPool()).query('SELECT id FROM app.posts LIMIT 20');
```

`cache()` only has an effect in server components; elsewhere each call makes a new `Pool`, which is still correct.

## Query caching and a cache-disabled binding

Hyperdrive caches read queries by default: `max_age` 60 seconds, `stale_while_revalidate` 15 seconds, at most one
hour. Writes, and queries that call volatile or stable functions (`now()`, `random()`, `current_date`), are not
cached. A function name inside an SQL comment can also stop caching, so keep comments out of hot queries. Hyperdrive
does not invalidate the cache when you write.

A 60-second-old read is fine for a content list and wrong for a permission check or a read right after a write. Run
two configurations on the same database:

```bash
npx wrangler hyperdrive create acme-db       --connection-string="$ORIGIN_URL"
npx wrangler hyperdrive create acme-db-fresh --connection-string="$ORIGIN_URL" --caching-disabled
```

```jsonc
"hyperdrive": [
  { "binding": "HYPERDRIVE",       "id": "<cached-config-id>" },
  { "binding": "HYPERDRIVE_FRESH", "id": "<cache-disabled-config-id>" }
]
```

Use `HYPERDRIVE_FRESH` for authorization and permission checks, sessions, billing, anything read right after it is
written, and auth libraries' queries. Use `HYPERDRIVE` for the rest. Both configurations share the origin's
connection limit.

## Transactions and session state under transaction pooling

Hyperdrive pools in transaction mode: a client holds one origin connection for a transaction, and the connection is
reset when it returns to the pool. One Worker invocation may use several origin connections.

- `SET` lasts only for the transaction or the single query that contains it; session `SET`, `search_path` and
  `statement_timeout` do not carry over. Set defaults on the database role instead (`ALTER ROLE ... SET`).
- Row-level security driven by `set_config('app.user_id', ..., true)` must be set inside every transaction; it does
  not survive between separate queries. Filtering by owner in the query (`WHERE owner_id = $1`) has no such failure
  mode.
- Keep transactions short, and never call another service (payments, email, an LLM) inside one: it holds an origin
  connection for the whole call.
- Session-level advisory locks and `LISTEN` do not fit transaction pooling; run them from a service with a direct
  connection.

## Hyperdrive limits

The limits that most often matter (check the Limits page for current values):

| Limit | Free | Paid |
|---|---|---|
| Origin connections per configuration | about 20 | about 100 |
| Initial connection timeout | 15 s | 15 s |
| Maximum query duration | 60 s | 60 s |
| Idle origin connection timeout | 10 min | 10 min |
| Maximum cached response size | 50 MB | 50 MB |
| Configurations per account | 10 | 25 |

Concurrent client connections from Workers are not limited by Hyperdrive; the origin connection count is.

## Migrations bypass Hyperdrive

Migration tools (drizzle-kit, Prisma Migrate, Alembic) are CLIs that cannot use a Worker binding and must not go
through a transaction pooler. Run them from CI with the direct database URL; the Worker uses the binding at run
time. Every migration still starts with `SET lock_timeout`, and indexes on big tables are built `CONCURRENTLY`
in their own step.

## Worked example: "move our Worker from a Neon HTTP driver to Hyperdrive"

The Worker uses `@neondatabase/serverless` over HTTP; queries take 40 ms each from far regions and transactions are
awkward. The move:

1. `npx wrangler hyperdrive create app-db --connection-string="$ORIGIN_URL"` with the database's direct
   (non-pooled) host, and a second configuration with `--caching-disabled` for fresh reads.
2. Add both bindings and `nodejs_compat` to `wrangler.jsonc`; `npm install pg@^8.16.3`.
3. Replace the module-scope `neon(...)` client with the per-request `Client` from the client section; route session
   and permission reads through `HYPERDRIVE_FRESH`.
4. Locally: `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE` and the `_HYPERDRIVE_FRESH` variable point at
   a local Postgres; `wrangler dev` runs the same code.
5. Check with `wrangler dev --remote` against staging: cached reads return in a few milliseconds, and a write
   followed by a fresh read shows the new value at once.

## Verify a Worker against Hyperdrive

Prove three things on a non-production configuration: the Worker reaches the database, the cache behaves as you
expect, and connections stay inside the origin's limit.

```bash
npx tsc --noEmit
npx wrangler dev --remote      # uses the real configuration; point it at staging, because writes are real
curl -s http://localhost:8787/ | head -c 200
npx wrangler hyperdrive get <hyperdrive-config-id>
```

Call a cached read twice and compare the times, then write through the fresh binding and read it back through the same
binding: the new value must appear at once. On the origin, `SELECT usename, count(*) FROM pg_stat_activity GROUP BY 1`
stays near the plan's connection limit under load. The commands were checked against the documentation; this skill
has no Cloudflare account behind it, so none of them ran here.

## Checklist

Check these points before you call a Worker that uses Hyperdrive done.

- [ ] `nodejs_compat` on; `pg` 8.16.3 or later; node-postgres for Drizzle.
- [ ] Client created per request from `env.HYPERDRIVE.connectionString`; nothing database-related at module scope.
- [ ] Permission checks, sessions and read-after-write use a cache-disabled binding.
- [ ] No reliance on session `SET`; role defaults or per-transaction settings instead.
- [ ] Transactions short, with no external calls inside.
- [ ] Local development uses `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_<BINDING>`, with no `if (dev)` branch.
- [ ] Migrations run from CI on the direct URL.

## Gotchas

These are the failures seen most often with a Worker that uses Hyperdrive, each with its cause and fix.

1. **"Cannot perform I/O on behalf of a different request".** A client or pool was created at module scope. Create
   it inside the handler.
2. **Users see stale permissions for a minute.** Hyperdrive cached the read. Route it through the cache-disabled
   binding.
3. **A query with `now()` is never cached.** Volatile and stable functions disable caching; pass the time as a
   parameter if the query should be cached.
4. **Works locally, slow or different in production.** Local development skips pooling and caching. Test with
   `wrangler dev --remote` against staging.
5. **The connection bypasses Hyperdrive.** A `neon-*` or HTTP driver was used. Use node-postgres.
6. **Queries killed at 60 seconds.** Hyperdrive's maximum query duration. Move long work to a job that connects
   directly, or make the query faster.

## Anti-patterns with Hyperdrive

| Do not | Do this instead |
|---|---|
| create a client or pool at module scope | create it inside the request |
| read permissions through a cached binding | a second configuration with `--caching-disabled` |
| rely on session `SET` between queries | role defaults, or `SET` inside one transaction |
| set `prepare: false` on Postgres.js | leave prepared statements on; Cloudflare warns of hangs |
| branch on `if (dev)` in the data layer | one binding with a local connection string |
| run migrations through the binding | CI on the direct URL |

## See also

- `postgres-connection-pooling`: transaction pooling in general.
- `postgres-drizzle`: Drizzle schema, queries and migrations.
- `postgres-node-typescript`: node-postgres and Postgres.js in depth.
- `postgres-schema-migrations`: safe DDL from CI.
- `postgres-security-roles`: a least-privilege role for Hyperdrive.

## Sources

- https://developers.cloudflare.com/hyperdrive/concepts/connection-pooling/ and /concepts/query-caching/
- https://developers.cloudflare.com/hyperdrive/configuration/local-development/
- https://developers.cloudflare.com/hyperdrive/platform/limits/
- https://developers.cloudflare.com/hyperdrive/examples/connect-to-postgres/ (drivers, node-postgres, Drizzle pages)
- https://opennext.js.org/cloudflare/howtos/db
- Run with `pg` 8.23.1 on PostgreSQL 18.6: `Pool` with `maxUses: 1`. Nothing here ran on Workers.
