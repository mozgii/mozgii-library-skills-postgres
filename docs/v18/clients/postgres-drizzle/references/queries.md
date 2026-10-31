---
title: Drizzle upserts, keyset pagination and raw SQL
author: MOZGII, Inc.
lang: en
---

# Drizzle upserts, keyset pagination and raw SQL

This reference covers the Drizzle query shapes that map to PostgreSQL features: `INSERT ... ON CONFLICT`, keyset pages,
and the `sql` template for everything the builder does not express.

## Upserts and keyset pagination

`onConflictDoUpdate` maps to `INSERT ... ON CONFLICT`; the target must match a unique constraint.

```ts
import { sql, or, lt } from 'drizzle-orm';

await db.insert(appUser).values({ id: userId, email })
  .onConflictDoUpdate({ target: appUser.id, set: { email: sql`excluded.email`, updatedAt: new Date() } });

// keyset pagination: the (createdAt, id) tiebreak is required
const page = await db.select().from(project)
  .where(cursor
    ? or(lt(project.createdAt, cursor.createdAt),
         and(eq(project.createdAt, cursor.createdAt), lt(project.id, cursor.id)))
    : undefined)
  .orderBy(desc(project.createdAt), desc(project.id))
  .limit(20);
```

## The sql escape hatch

`sql` is the right tool for window functions, `excluded.*`, functional indexes, full-text search, `DISTINCT ON` and
pgvector. Type it (`sql<number>\`count(*)\``) or the result is `unknown`. Values interpolated into `sql` are
parameters; `sql.raw()` is not parameterized and must never receive user input.
