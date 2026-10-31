---
name: postgres-app-drivers
description: 'Connects applications to PostgreSQL correctly in Node.js and TypeScript, Go, Java, .NET and Rust: choosing a driver or ORM (node-postgres, postgres.js, Prisma 7, Kysely, pgx, sqlc, JDBC with HikariCP, Npgsql, SQLx), pools, parameters, transactions with retries, bigint, numeric, date and timestamp mapping, COPY, TLS and timeouts. Use when writing data access code outside Python, picking a client library, or for "ids come back as strings", dates off by a day, leaked connections or crashes when the database restarts.'
metadata:
  tags:
  - postgres
  - drivers
  - orm
  - node-postgres
  - prisma
  - kysely
  - pgx
  - jdbc
  - npgsql
  - sqlx
  - typescript
---

# PostgreSQL drivers and ORMs for applications

Every language has a good PostgreSQL driver; the bugs come from the same few places in all of them: pools, parameter
handling, transactions, and type mapping. This skill gives the rules once and the code per language. Python lives in
`postgres-python`; Drizzle in `postgres-drizzle`. Detail:
[Node.js drivers](references/node.md), [Prisma 7](references/prisma.md),
[Go, Java, .NET and Rust](references/go-java-dotnet-rust.md).

## Step 0: read installed versions

Driver APIs change between majors; read what the project uses before writing code.

```bash
npm ls pg postgres @prisma/client prisma drizzle-orm kysely 2>/dev/null
go list -m github.com/jackc/pgx/v5 2>/dev/null
grep -E 'postgresql|Npgsql|sqlx' pom.xml build.gradle* *.csproj Cargo.toml 2>/dev/null
```

Current versions (October 2026): `pg` 8.23.1, `postgres` 4.0.0, Prisma 7.10.1, `drizzle-orm` 0.45.4, Kysely 0.29.7,
pgx v5.11.0, sqlc v1.31.1, PgJDBC 42.7.14, Npgsql 10.0.3, SQLx 0.9.0.

## Choosing a driver or ORM

Pick the thinnest layer that fits the team: a query builder or a SQL-first generator keeps Postgres features in
reach; a full ORM saves code for CRUD-heavy apps.

| Language | Driver | Query builder / SQL-first | ORM |
|---|---|---|---|
| Node.js / TypeScript | `pg` (node-postgres), `postgres` (postgres.js) | Kysely, Drizzle | Prisma, Drizzle, TypeORM, Sequelize |
| Go | pgx v5 (`pgxpool`) | sqlc (generates typed code from SQL), squirrel | GORM, ent |
| Java / Kotlin | PgJDBC + HikariCP, R2DBC for reactive | jOOQ | Hibernate / JPA, Exposed |
| .NET | Npgsql | Dapper | EF Core with `Npgsql.EntityFrameworkCore.PostgreSQL` |
| Rust | SQLx (compile-time checked SQL), tokio-postgres | SeaQuery | Diesel, SeaORM |

## Rules every driver must follow

These rules apply in every language.

1. **One pool per process**, created at startup and shared; set its maximum, connect timeout and idle timeout
   (`postgres-connection-pooling`).
2. **Parameters, never string building**, for every value. Identifiers come from an allowlist.
3. **Release connections in `finally` / `defer` / `using`**; a leak looks like a too-small pool.
4. **Transactions through the driver's helper** (callback or scope), so an error always rolls back; never use the
   pool directly inside a transaction callback, use the transaction's client.
5. **Retry** transactions on SQLSTATE `40001` (serialization failure) and `40P01` (deadlock), with jittered backoff
   and an attempt cap. Do not retry other errors blindly.
6. **Timeouts**: a statement timeout per role or connection, and a client-side query timeout.
7. **TLS** with certificate verification (`sslmode=verify-full` or the driver's equivalent) to any server off the
   local machine.
8. **Credentials** from the environment or a secret store at run time, never in code or the repository.

## Type mapping traps

Postgres types do not all map cleanly to language types; each driver picks a default you must know.

| Postgres | Trap | Fix |
|---|---|---|
| `bigint` (`int8`) | node-postgres and postgres.js return strings (JS numbers lose precision past 2^53) | keep strings, or parse to `BigInt` explicitly |
| `numeric` | returned as string in JS, `BigDecimal`/`decimal` elsewhere | never parse money to a float |
| `timestamptz` | becomes a `Date` / `Instant` in UTC; `timestamp` (no zone) is read in the client's local zone | use `timestamptz` columns; set the client zone to UTC |
| `date` | node-postgres turns it into a local-midnight `Date` | parse `date` (OID 1082) as a string |
| `json` / `jsonb` | parsed objects; sending a JS array as a parameter becomes a Postgres array, not JSON | `JSON.stringify` arrays bound to `jsonb` |
| arrays | supported natively | send arrays to `= ANY($1)` instead of building `IN` lists |
| `uuid` | string in JS, `UUID` / `Guid` elsewhere | |

## Transactions with retry, in TypeScript

A transaction helper with retry, in the shape most drivers allow. This one uses node-postgres.

```ts
import pg from 'pg';

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 5_000,
  statement_timeout: 30_000, application_name: 'app-api',
});

const RETRY = new Set(['40001', '40P01']);

async function runTx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

export async function withTx<T>(fn: (c: pg.PoolClient) => Promise<T>, attempts = 3): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await runTx(fn);
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (!code || !RETRY.has(code) || i >= attempts) throw err;
    }
    await new Promise((r) => setTimeout(r, 2 ** i * 25 + Math.random() * 50));
  }
}
```

The backoff sleeps after `runTx` has released its client, so a waiting retry never holds a connection the rest of the
pool needs. With `max: 1` and a callback that failed twice with `40001`, this helper finished on the third attempt
(`pg` 8.23.1 on 18.6).

## Bulk loading with COPY from application code

`COPY` is the fastest way to load rows; every major driver exposes it.

| Driver | API |
|---|---|
| node-postgres | `pg-copy-streams`: `client.query(copyFrom('COPY t (a, b) FROM STDIN WITH (FORMAT csv)'))` |
| postgres.js | ``await sql`COPY t FROM STDIN`.writable()`` |
| pgx | `conn.CopyFrom(ctx, pgx.Identifier{"t"}, []string{"a", "b"}, pgx.CopyFromRows(rows))` |
| PgJDBC | `conn.unwrap(PGConnection.class).getCopyAPI().copyIn("COPY t FROM STDIN WITH (FORMAT csv)", reader)` |
| Npgsql | `conn.BeginBinaryImport("COPY t (a, b) FROM STDIN (FORMAT BINARY)")` |
| SQLx | `conn.copy_in_raw("COPY t FROM STDIN")` |

A pool hands out a wrapper, so a cast to a driver class fails: HikariCP's proxy is not a `BaseConnection` and throws
`ClassCastException`. `unwrap` reaches the real connection.

## Worked example: "our Node API crashes whenever the database restarts"

The process exits with `Error: Connection terminated unexpectedly` from an idle pool client. node-postgres emits
`error` on the pool when an idle connection dies, and an `EventEmitter` error with no listener ends the process.
Handle it once at startup, and let the pool replace the connection:

```ts
pool.on('error', (err) => {
  console.warn('idle postgres client failed; the pool will reconnect', (err as { code?: string }).code);
});
```

Requests that were mid-query during the restart still fail: they get a `57P01` (`admin_shutdown`) or a connection
error. Retry those only when the statement is safe to repeat (a read, or a write with an idempotency key), using the
same jittered backoff as the transaction helper above. Test it: run the API, restart Postgres, and check that the
process stays up and the next request succeeds.

## Verify pools, retries and restarts against a real server

A mock cannot show a leaked connection or a failed reconnect, so run these three checks against a real server.

1. Pool release: set the pool's maximum to 1 and run the retry helper with a callback that throws `40001` twice. It
   must succeed on the third attempt; a client held during the backoff makes the next `pool.connect()` time out.
2. Restart: with the service running, restart PostgreSQL. The process stays up and the next request succeeds.
3. Connection count: under load, this query shows the pool's maximum at most, with `application_name` set.

```sql
SELECT application_name, state, count(*)
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

## Checklist

Check these points before you call application database code done.

- [ ] One pool per process with explicit limits; connections released in `finally`.
- [ ] Every value bound as a parameter.
- [ ] Transactions use the driver's helper and its client; retries on `40001` and `40P01` only.
- [ ] `bigint`, `numeric` and `date` mapping chosen on purpose; no money in floats.
- [ ] TLS verifies the server certificate; credentials come from the environment.
- [ ] Statement timeout set; slow queries visible in `pg_stat_statements`.
- [ ] Bulk loads use `COPY` or array parameters.

## Gotchas

These are the failures seen most often with application database code, each with its cause and fix.

1. **IDs come back as strings in Node.** `int8` is returned as a string by design. Use strings for ids, or set a
   type parser to `BigInt`.
2. **A date shifts by one day.** node-postgres turned a `date` into a `Date` at local midnight, then it was printed
   in UTC. Parse OID 1082 as a string.
3. **`prepared statement does not exist` behind a pooler.** The pooler is in transaction mode without prepared
   statement support. Upgrade PgBouncer to 1.21 or later with `max_prepared_statements` above 0, or turn prepares
   off in the driver (postgres.js `prepare: false`, JDBC `prepareThreshold=0`, pgx `default_query_exec_mode=exec`).
4. **Queries inside a transaction callback run outside it.** The code used the pool (or the outer ORM client)
   instead of the transaction client.
5. **`npm install prisma` installed a release candidate.** In October 2026 Prisma's npm `latest` tag points to
   8.0.0-rc; pin `prisma@7.10.1` and `@prisma/client@7.10.1` ([references/prisma.md](references/prisma.md)).
6. **Too many connections from tests.** Each test file created its own pool and never closed it. Share one and call
   `pool.end()` in teardown.

## Anti-patterns in application database code

| Do not | Do this instead |
|---|---|
| open a pool per request or per test file | one pool per process, closed at shutdown |
| build SQL with string concatenation | bind every value; take identifiers from an allowlist |
| sleep or call another service while holding a connection | release it first, and keep work outside the transaction |
| retry on any error | retry `40001` and `40P01`, with a cap and jitter |
| cast a pooled connection to a driver class | `unwrap` it |
| read `numeric` into a float | a string, `BigDecimal` or `decimal` |

## See also

- `postgres-connection-pooling`: pool sizes, PgBouncer and prepared statements.
- `postgres-transactions-locking`: isolation levels and what to retry.
- `postgres-node-typescript`, `postgres-go-pgx`, `postgres-java-jdbc`, `postgres-dotnet-npgsql`, `postgres-rust-sqlx`:
  one language in depth.
- `postgres-python` and `postgres-drizzle`: Python and Drizzle ORM.
- `postgres-encryption-tls`: `verify-full` and client certificates.

## Sources

- https://node-postgres.com/ and https://github.com/porsager/postgres (README, 4.0.0)
- https://pgjdbc.org/documentation/ (`PGConnection`, `CopyManager`)
- https://pkg.go.dev/github.com/jackc/pgx/v5
- https://www.npgsql.org/doc/copy.html
- https://www.postgresql.org/docs/18/errcodes-appendix.html
- Run with `pg` 8.23.1 and `postgres` 4.0.0 on 18.6: the retry helper with a pool of one, `COPY` through `.writable()`.
