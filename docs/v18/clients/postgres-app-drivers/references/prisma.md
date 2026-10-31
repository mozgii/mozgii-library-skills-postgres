---
title: Prisma ORM 7 with PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Prisma ORM 7 with PostgreSQL

This reference covers Prisma ORM 7 with PostgreSQL: the install trap, configuration, the driver adapter, queries,
transactions and migrations.

## Contents

The sections of this reference on prisma ORM 7 with PostgreSQL:

1. Install Prisma 7 with pinned versions
2. prisma.config.ts and schema.prisma
3. The PostgreSQL driver adapter
4. Queries and transactions in Prisma
5. Prisma Migrate workflow

## Install Prisma 7 with pinned versions

In October 2026 the npm `latest` tag of `prisma` points to an 8.0.0 release candidate while `@prisma/client` latest
is 7.10.1, so an unpinned install mixes majors. Pin both.

```bash
npm install @prisma/client@7.10.1 @prisma/adapter-pg@7.10.1 pg dotenv
npm install -D prisma@7.10.1
```

Prisma 7 needs Node.js 20.19 or later and TypeScript 5.4 or later, and ships as ES modules (`"type": "module"`).

## prisma.config.ts and schema.prisma

Prisma 7 moves connection settings out of `schema.prisma` into `prisma.config.ts`, and the client is generated into
your source tree, not `node_modules`.

```ts
// prisma.config.ts
import 'dotenv/config';
import { defineConfig, env } from 'prisma/config';

export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: { path: 'prisma/migrations', seed: 'tsx prisma/seed.ts' },
  datasource: { url: env('DIRECT_DATABASE_URL') },   // the CLI (migrate) uses the direct, unpooled URL
});
```

```prisma
// prisma/schema.prisma
generator client {
  provider = "prisma-client"
  output   = "../src/generated/prisma"
}

datasource db {
  provider = "postgresql"
}

model Customer {
  id        BigInt   @id @default(autoincrement())
  email     String   @unique
  createdAt DateTime @default(now()) @map("created_at") @db.Timestamptz(6)
  orders    Order[]
  @@map("customers")
}

model Order {
  id         BigInt   @id @default(autoincrement())
  customerId BigInt   @map("customer_id")
  totalCents BigInt   @map("total_cents")
  customer   Customer @relation(fields: [customerId], references: [id])
  @@index([customerId])
  @@map("orders")
}
```

- Use `@db.Timestamptz(6)`: Prisma's default `DateTime` maps to `timestamp(3)` without time zone.
- Add `@@index` for foreign key fields; Prisma does not create them on PostgreSQL.

## The PostgreSQL driver adapter

Prisma 7 talks to PostgreSQL through a driver adapter; `@prisma/adapter-pg` uses node-postgres.

```ts
import { PrismaClient } from './generated/prisma/client';
import { PrismaPg } from '@prisma/adapter-pg';

const adapter = new PrismaPg({ connectionString: process.env.DATABASE_URL, max: 10 });
export const prisma = new PrismaClient({ adapter });
```

- The runtime URL may be pooled; migrations use the direct URL from `prisma.config.ts`.
- TLS is now validated by `pg`: provide the CA (`NODE_EXTRA_CA_CERTS`) instead of turning verification off.
- In dev servers with hot reload, keep one client on `globalThis` so each reload does not open a new pool.

## Queries and transactions in Prisma

Prisma's client API covers CRUD; `$transaction` groups writes; typed raw SQL covers the rest.

```ts
const customer = await prisma.customer.upsert({
  where: { email }, update: {}, create: { email },
});

await prisma.$transaction(async (tx) => {
  const order = await tx.order.create({ data: { customerId: customer.id, totalCents: 1999n } });
  await tx.$executeRaw`UPDATE app.stock SET qty = qty - 1 WHERE sku = ${sku}`;   // tagged: parameterized
  return order;
}, { isolationLevel: 'Serializable', timeout: 10_000 });
```

- `$queryRaw` and `$executeRaw` tagged templates are parameterized; `$queryRawUnsafe` is not. Never pass user input
  to the unsafe variants.
- `$use` middleware was removed in Prisma 7; use client extensions (`prisma.$extends({ query: ... })`).
- Retry `Serializable` transactions on error code `P2034` (Prisma's write conflict), which wraps `40001`.

## Prisma Migrate workflow

`prisma migrate dev` creates SQL migration files in development; `prisma migrate deploy` applies them in CI and
production.

```bash
npx prisma migrate dev --name add_orders          # dev only: may reset the dev database
npx prisma generate                                # Prisma 7: migrate dev no longer runs generate
npx prisma migrate deploy                          # CI / production: applies pending migrations only
npx prisma migrate dev --create-only --name idx    # create an empty migration to hand-edit (e.g. CONCURRENTLY)
```

- Never run `migrate dev` or `db push` against production.
- Review each generated SQL file for locks and renames (`postgres-schema-migrations`).
- Seeding no longer runs automatically; call `npx prisma db seed`.
