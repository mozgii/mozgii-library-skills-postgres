---
title: Drizzle with Next.js 16 and Cloudflare Workers
author: MOZGII, Inc.
lang: en
---

# Drizzle with Next.js 16 and Cloudflare Workers

Next.js 16 adds rules for where data access may run and how cached reads are invalidated; on Cloudflare Workers
(OpenNext) the database client is created per request. This reference covers both, for Drizzle 0.45.

## Contents

This reference covers the following topics.

- The database client on Cloudflare Workers
- Next.js rules for data access
- Next.js and Drizzle mistakes to avoid

## The database client on Cloudflare Workers

On Workers an I/O object cannot cross a request boundary, so a module-scope client fails with "Cannot perform I/O on
behalf of a different request". Create the database object per request from the Hyperdrive binding; React `cache()`
memoizes it within one request in server components. A cached client has no place to call `client.end()`, so use a
`Pool` with `maxUses: 1`, the form OpenNext documents: `pg` closes each connection when it is released, after a single
query or transaction (tested with `pg` 8.23.1, 0 connections left), and Hyperdrive keeps the real pool.

```ts
// src/db/index.ts (Next.js on Workers with OpenNext)
import 'server-only';
import { cache } from 'react';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import * as tables from './schema';
import * as relations from './relations';

const schema = { ...tables, ...relations };

export const getDb = cache(async () => {
  const { env } = await getCloudflareContext({ async: true });
  const pool = new Pool({ connectionString: env.HYPERDRIVE.connectionString, maxUses: 1 });
  return drizzle({ client: pool, schema, casing: 'snake_case' });
});
```

A plain Worker, without Next.js, closes one client per request after the response. Create it inside the handler:

```ts
// Cloudflare Worker: one client per request, through Hyperdrive
import { drizzle } from 'drizzle-orm/node-postgres';
import { Client } from 'pg';
import * as schema from './db/schema';

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext) {
    const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
    await client.connect();
    const db = drizzle({ client, schema, casing: 'snake_case' });
    try {
      return Response.json(await db.select().from(schema.project).limit(20));
    } finally {
      ctx.waitUntil(client.end());
    }
  },
} satisfies ExportedHandler<Env>;
```

Use `node-postgres` here: Cloudflare documents Drizzle with postgres.js over Hyperdrive as unsupported, and `neon-*`
drivers bypass Hyperdrive. Hyperdrive caches reads for 60 seconds by default: read permissions and anything just written
through a second binding with caching disabled.

## Next.js rules for data access

Drizzle runs in Server Components, Server Actions and Route Handlers, never in Client Components.

- **`'use cache'` functions must be pure functions of their arguments.** Reading `cookies()` or `headers()` inside a
  `'use cache'` scope is an error. Read request data in the caller and pass the id in; it becomes part of the cache
  key. `'use cache'` needs `cacheComponents: true` in `next.config`.

```ts
import { cacheLife, cacheTag } from 'next/cache';

export async function getProjects(userId: string) {
  'use cache';
  cacheTag(`projects:${userId}`);
  cacheLife('minutes');
  return db.query.project.findMany({ where: (p, { eq }) => eq(p.ownerId, userId) });
}
```

- **Server Actions are public HTTP endpoints.** Each one authenticates, authorizes, then validates input with the
  drizzle-zod schema before it queries.
- **Never pass client-supplied objects into the query builder**: no client-controlled `where`, `orderBy`, column list
  or table name. Allowlist fields.
- **Invalidate after the write resolves**: in a Server Action, `updateTag('projects:' + userId)` after the `await`;
  elsewhere `revalidateTag(tag, 'max')` (the one-argument form is deprecated in Next.js 16).

## Next.js and Drizzle mistakes to avoid

These are the mistakes seen most often with Drizzle code in a Next.js app, each with the reason it fails.

| Never | Why |
|---|---|
| `defineRelations()` on `drizzle-orm@latest` | not in 0.45; needs the RC |
| A module-scope client on Workers | I/O cannot cross request boundaries |
| A new `Pool` per hot reload in dev | exhausts connections; keep it on `globalThis` |
| Outer `db` inside `db.transaction` | silently non-atomic |
| Network calls inside a transaction | holds a connection and locks |
| `drizzle-kit` in `dependencies` | bundles esbuild into the app |
| A client file without `import 'server-only'` | one stray import leaks the connection string; keep it out of `schema.ts`, which `drizzle-kit` loads under Node |
| `cookies()` inside `'use cache'` | error; pass the id as an argument |
| A Server Action without an auth check | it is a public endpoint |
| `sql.raw(userInput)` | SQL injection |
| `serial` for a new key | use identity |
| `timestamp()` without `withTimezone` | wrong after any zone change |
| `OFFSET` on deep pages | use keyset with a tiebreak |
| `{ email: z.string().email() }` in drizzle-zod to refine a column | a bare schema replaces the whole field, nullability included; use `(s) => s.email()` |
| A query per row inside `.map()` | N+1; fetch the tree with `with` |
| Upgrading to TypeScript 7 without a check | `npm install typescript` now gives 7.0; in our test drizzle-zod 0.8.3's refinement callbacks failed to type-check under 7.0.2 and passed under 5.9.3 |