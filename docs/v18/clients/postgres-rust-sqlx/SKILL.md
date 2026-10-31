---
name: postgres-rust-sqlx
description: 'Builds Rust services on PostgreSQL with SQLx 0.9, tokio-postgres with deadpool-postgres, and Diesel 2.3 with diesel-async: quickstart, PgPoolOptions, query! compile-time checks and offline mode (cargo sqlx prepare), sqlx-cli migrations, transactions with retries, COPY, PgListener, type mapping for chrono, time, uuid, rust_decimal and JSON, SQLSTATE errors. Use when writing Rust code against Postgres, CI fails with "set DATABASE_URL to use query macros online", choosing between SQLx, Diesel and SeaORM, or a Rust service hangs on shutdown.'
metadata:
  tags:
  - postgres
  - rust
  - sqlx
  - tokio-postgres
  - deadpool-postgres
  - diesel
  - diesel-async
  - seaorm
  - migrations
---

# PostgreSQL from Rust with SQLx, tokio-postgres and Diesel

Pick SQLx when the team writes SQL and wants the compiler to check it; tokio-postgres with deadpool-postgres when
you need binary COPY, explicit pipelining or the thinnest async layer; Diesel 2.3 (with diesel-async for async code)
when you want a typed query builder and schema in Rust; SeaORM 2.0 for an ActiveRecord-style ORM built on SQLx. The
short chooser across languages is `postgres-app-drivers`; this skill goes deep on Rust. Pool sizing and PgBouncer
live in `postgres-connection-pooling`, lock-safe DDL in `postgres-schema-migrations`, isolation and retries in
`postgres-transactions-locking`. Detail: [references/sqlx-copy-listen-errors.md](references/sqlx-copy-listen-errors.md),
[references/tokio-postgres-diesel.md](references/tokio-postgres-diesel.md).

## Rust quickstart: connect, query and close with SQLx

This Rust quickstart creates a project, adds SQLx and Tokio, and runs a program that connects, queries and closes
the pool. SQLx is pure Rust (no libpq, no C toolchain), so the steps work on macOS, Linux and Windows; in PowerShell
set the variable with `$env:DATABASE_URL = "..."`.

```bash
cargo new pgquick && cd pgquick
cargo add sqlx --features runtime-tokio,tls-rustls,postgres,macros,migrate,chrono,uuid,rust_decimal,json
cargo add tokio --features macros,rt-multi-thread
cargo add chrono
```

The program below replaces `src/main.rs`; it reads `DATABASE_URL`, runs two parameterized queries and closes the pool.

```rust
use sqlx::postgres::PgPoolOptions;

#[tokio::main]
async fn main() -> Result<(), sqlx::Error> {
    let url = std::env::var("DATABASE_URL").expect("set DATABASE_URL");
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&url)
        .await?;

    let (version, now): (String, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as("SELECT version(), now()").fetch_one(&pool).await?;
    let answer: i64 = sqlx::query_scalar("SELECT $1::int8 * 2").bind(21_i64).fetch_one(&pool).await?;
    println!("{version}\n{now} answer={answer}");

    pool.close().await;
    Ok(())
}
```

Run it with `DATABASE_URL=postgres://app:secret@localhost:5432/app cargo run`. Add `?sslmode=verify-full` for any
server off the machine; SQLx defaults to `prefer`, which encrypts without checking the certificate.

## Step 0: read the Rust crate versions in the project

Rust crate APIs change between minor versions before 1.0 (SQLx 0.8 to 0.9 broke dynamic queries), so read what the
project resolves before writing code.

```bash
cargo tree --depth 1 -e normal | grep -E 'sqlx|tokio-postgres|deadpool|diesel|sea-orm'
rustc --version            # SQLx 0.9 needs Rust 1.94 or later
```

Current in October 2026: `sqlx` and `sqlx-cli` 0.9.0, `tokio-postgres` 0.7.18, `deadpool-postgres` 0.14.2,
`diesel` 2.3.14, `diesel-async` 0.9.2, `sea-orm` 2.0.4.

## Choosing SQLx, tokio-postgres, Diesel or SeaORM in Rust

Each Rust option trades checking for control in a different place.

| Crate | Queries are | Checked | Async | Pick it for |
|---|---|---|---|---|
| SQLx 0.9 | plain SQL strings | at compile time against a live database or the `.sqlx` cache | yes (Tokio, smol) | most services; SQL-first teams |
| tokio-postgres 0.7 + deadpool-postgres 0.14 | plain SQL strings | at run time | yes (Tokio) | binary COPY, pipelining, custom types, smallest layer |
| Diesel 2.3 (+ diesel-async 0.9) | a Rust query DSL from `schema.rs` | by the type system | sync; async with diesel-async | complex typed queries, refactor safety |
| SeaORM 2.0 | entities and a builder (SeaQuery) | partly, by types | yes (on SQLx) | CRUD-heavy apps that want an ORM |

## SQLx PgPoolOptions and connection options

`PgPoolOptions` builds the one pool per process; `PgConnectOptions` sets per-connection settings. Create the pool
once at startup and share the `PgPool` (it is an `Arc` inside, so cloning is cheap).

| Option | SQLx 0.9 default | Set it to |
|---|---|---|
| `max_connections` | 10 | the share of `max_connections` this process may use (`postgres-connection-pooling`) |
| `min_connections` | 0 | 1 or more to keep a warm connection |
| `acquire_timeout` | 30 s | 3 to 5 s, so an exhausted pool fails fast |
| `idle_timeout` | 10 min | keep, or lower behind a pooler that closes idle links |
| `max_lifetime` | 30 min | keep; it rotates connections after failovers |
| `statement_cache_capacity` (connect option) | 100 statements | 0 only behind a pooler that cannot track prepared statements |

The snippet below sets server settings at connect time, so every pooled connection carries the timeouts. In 0.9,
`options()` escapes values itself; do not pre-escape them.

```rust
let opts = std::env::var("DATABASE_URL")?
    .parse::<sqlx::postgres::PgConnectOptions>()?
    .application_name("orders-api")
    .options([("statement_timeout", "30s"), ("lock_timeout", "5s")]);
let pool = sqlx::postgres::PgPoolOptions::new()
    .max_connections(10)
    .min_connections(1)
    .acquire_timeout(std::time::Duration::from_secs(5))
    .connect_with(opts)
    .await?;
```

## SQLx compile-time checked queries with query! and query_as!

The `query!` family sends each SQL string to the database named by `DATABASE_URL` at build time, asks Postgres for
the parameter and column types, and fails the build when the SQL or the Rust types are wrong. Nullability is
inferred: a column that can be NULL becomes `Option<T>`.

This query maps rows into a struct, overrides one column's Rust type, and forces a non-null count.

```rust
#[derive(Debug, sqlx::FromRow)]
struct Order { id: uuid::Uuid, email: String, total: rust_decimal::Decimal,
               meta: sqlx::types::Json<Meta>, placed_at: chrono::DateTime<chrono::Utc>, note: Option<String> }

let o = sqlx::query_as!(Order,
    r#"SELECT id, email, total, meta AS "meta: Json<Meta>", placed_at, note FROM orders WHERE id = $1"#, id)
    .fetch_one(&pool).await?;

let n = sqlx::query_scalar!(r#"SELECT count(*) AS "n!" FROM orders WHERE email = ANY($1)"#,
    &emails as &[String]).fetch_one(&pool).await?;      // n: i64, not Option<i64>
```

Column overrides: `"col!"` non-null, `"col?"` nullable, `"col: Type"` a Rust type, `"col!: Type"` both. A custom
type bound into `query!` needs `value as _`. SQLx 0.9 describes queries with a generic plan, which can change
inferred nullability from 0.8: rebuild and read the diffs after upgrading.

## SQLx offline mode with cargo sqlx prepare for CI

Offline mode lets CI and Docker builds compile `query!` macros without a database. `cargo sqlx prepare` writes one
JSON file per query into `.sqlx/`; commit that folder. When `DATABASE_URL` is unset the macros read `.sqlx`
automatically; `SQLX_OFFLINE=true` forces the cache even when the variable is set.

```bash
cargo install sqlx-cli --no-default-features --features postgres,rustls
cargo sqlx prepare                  # run against a migrated database; writes .sqlx/query-<hash>.json
cargo sqlx prepare --check          # in CI: fails when .sqlx is stale
SQLX_OFFLINE=true cargo build       # build without a database
cargo sqlx prepare --workspace      # for a Cargo workspace
```

Without both a database and `.sqlx`, the build stops with `set DATABASE_URL to use query macros online, or run
cargo sqlx prepare to update the query cache`.

## SQLx migrations with sqlx-cli and migrate!

sqlx-cli manages numbered SQL files in `migrations/` and records them in the `_sqlx_migrations` table.
`sqlx::migrate!()` embeds the same files into the binary so the service can migrate itself at startup.

```bash
sqlx database create                       # creates the database in DATABASE_URL
sqlx migrate add -r create_orders          # -r: reversible, writes <ts>_create_orders.up.sql and .down.sql
sqlx migrate run                           # applies pending files; each runs in its own transaction
sqlx migrate revert                        # runs the latest .down.sql
sqlx migrate info
```

Each file runs inside a transaction, and `CREATE INDEX CONCURRENTLY` refuses to run in one. Put `-- no-transaction`
on the first line of that file:

```sql
-- no-transaction
CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_email_idx ON orders (email);
```

`sqlx::migrate!("./migrations").run(&pool).await?` takes an advisory lock, so two replicas starting at once do not
both migrate. Never edit an applied file: its checksum is stored and `run` refuses a changed one.

## SQLx transactions and retrying serialization failures

`pool.begin()` returns a `Transaction`; pass `&mut *tx` as the executor, call `commit()`, and a transaction dropped
without commit rolls back. This helper retries the whole transaction on `40001` and `40P01` only.

```rust
async fn place(pool: &PgPool, email: &str, total: Decimal) -> Result<Uuid, sqlx::Error> {
    for attempt in 1..=3u32 {
        let mut tx = pool.begin().await?;
        let r: Result<Uuid, sqlx::Error> = async {
            sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE").execute(&mut *tx).await?;
            sqlx::query_scalar!("INSERT INTO orders (email, total) VALUES ($1, $2) RETURNING id", email, total)
                .fetch_one(&mut *tx).await
        }.await;
        match r {
            Ok(id) => { tx.commit().await?; return Ok(id); }
            Err(sqlx::Error::Database(e))
                if matches!(e.code().as_deref(), Some("40001" | "40P01")) && attempt < 3 => {
                drop(tx);                                                   // rolls back
                tokio::time::sleep(std::time::Duration::from_millis(25 * 2u64.pow(attempt))).await;
            }
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}
```

## SQLx dynamic SQL, COPY, LISTEN and errors in brief

SQLx 0.9 query functions take only `&'static str` or `AssertSqlSafe(sql)`, so wrap reviewed dynamic SQL whose
identifiers come from an allowlist, or build it with `QueryBuilder::push_bind`. `PgConnection::copy_in_raw("COPY ...
FROM STDIN")` loads rows fastest; `UNNEST($1::text[], ...)` suits upserts of a few thousand rows. `PgListener`
yields notifications on its own connection; a listener built with `connect_with(&pool)` holds a pool connection, so
drop it before `pool.close()`. Match errors by SQLSTATE through `err.as_database_error()` and `db.code()`:
`23505` unique, `40001` and `40P01` retry, `57014` statement timeout. Code for all four:
[references/sqlx-copy-listen-errors.md](references/sqlx-copy-listen-errors.md).

## Rust type mapping for PostgreSQL types in SQLx

SQLx maps each Postgres type to one or more Rust types behind a feature flag; enable only the crates you use.

| Postgres | Rust (feature) | Notes |
|---|---|---|
| `int2`, `int4`, `int8` | `i16`, `i32`, `i64` | no unsigned integers; `u64` ids do not exist |
| `numeric` | `rust_decimal::Decimal` (`rust_decimal`) or `BigDecimal` (`bigdecimal`) | never `f64` for money |
| `timestamptz` | `chrono::DateTime<Utc>` (`chrono`) or `time::OffsetDateTime` (`time`) | stored as UTC |
| `timestamp`, `date`, `time` | `NaiveDateTime`, `NaiveDate`, `NaiveTime` or `time::PrimitiveDateTime`, `Date`, `Time` | |
| `interval` | `sqlx::postgres::types::PgInterval` | months, days and microseconds stay separate |
| `uuid` | `uuid::Uuid` (`uuid`) | Postgres 18 `uuidv7()` defaults sort by time |
| `jsonb`, `json` | `sqlx::types::Json<T>`, `serde_json::Value` (`json`) | `Json<T>` with a `serde` struct |
| `text[]`, `int8[]` | `Vec<String>`, `Vec<i64>`, `&[T]` for parameters | |
| `bytea` | `Vec<u8>`, `&[u8]` | |
| custom enum, composite, domain | `#[derive(sqlx::Type)]` with `#[sqlx(type_name = "...")]` | |

When both `chrono` and `time` are enabled, the macros pick `time`; set `[macros.preferred-crates] date-time =
"chrono"` in `sqlx.toml` to choose. Likewise `bigdecimal` wins over `rust_decimal` unless configured.

## tokio-postgres, Diesel and SeaORM in brief

tokio-postgres with deadpool-postgres pipelines queries issued concurrently on one client and loads typed rows with
`BinaryCopyInWriter`; TLS needs `tokio-postgres-rustls` or `postgres-native-tls`. Diesel 2.3 checks queries against
`src/schema.rs` (written by `diesel migration run`); diesel-async 0.9 adds `AsyncPgConnection` without libpq, pools,
`AsyncMigrationHarness`, and transactions as async closures (`async |conn| { ... }`). SeaORM 2.0 runs on SQLx 0.9,
so the SQLx rules here apply to it. Programs and diesel_cli installs per OS:
[references/tokio-postgres-diesel.md](references/tokio-postgres-diesel.md).

## Gotchas

The Rust and Postgres failures seen most often, each with its cause and fix.

1. **CI fails with `set DATABASE_URL to use query macros online`.** No database and no `.sqlx` cache at build
   time. Run `cargo sqlx prepare`, commit `.sqlx/`, and add `cargo sqlx prepare --check` to CI.
2. **`dynamic SQL strings should be audited for possible injections` after upgrading to 0.9.** Query functions
   take only static strings (the `SqlSafeStr` trait). Use `query!`; wrap reviewed dynamic SQL in `AssertSqlSafe`.
3. **The service hangs on shutdown.** `pool.close().await` waits for every checked-out connection, including one
   held by a `PgListener`, a stream or a long task. Drop them first, or race them against `pool.close_event()`.
4. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block` from a migration.** The tool wrapped the
   file in a transaction. SQLx: `-- no-transaction` first line; Diesel: `metadata.toml` with
   `run_in_transaction = false`.
5. **`prepared statement "sqlx_s_1" does not exist` behind PgBouncer.** Transaction pooling without prepared
   statement tracking. Use PgBouncer 1.21 or later with `max_prepared_statements` above 0, or set
   `statement_cache_capacity(0)` and `.persistent(false)` on queries.
6. **`query!` returns `Option<i64>` for a count.** Postgres cannot prove an aggregate, outer-join or expression
   column is non-null. Override with `AS "col!"`.

## Anti-patterns in Rust database code

The compiler catches many mistakes here; it does not catch these.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| A new pool per request | connections multiply and each request pays for a connect | one `PgPool` built at startup, shared by clone |
| `format!` into SQL, or `AssertSqlSafe` around user input | SQL injection that the 0.9 type check was meant to stop | bind values; identifiers from an allowlist; `QueryBuilder::push_bind` |
| `f64` for money | rounding errors in totals | `rust_decimal::Decimal` or `BigDecimal` |
| `.await` on an outside service inside a `Transaction` | row locks and a pool connection stay held for the whole call | commit first, or call the service before `begin()` |
| Editing an applied migration file | `sqlx migrate run` refuses the changed checksum | add a new migration |
| Retrying every `sqlx::Error` | a syntax error or a unique violation loops | retry on `40001` and `40P01` only |
| A stale `.sqlx` folder | CI builds against queries that no longer match | `cargo sqlx prepare --check` in CI |

## Verify SQLx queries and migrations in CI

SQLx's checks run at build time, so CI proves them with a migrated database and again with none. These commands come
from the sqlx-cli README and source; they were not run here, because the test machine had no Rust toolchain.

```bash
sqlx database create            # uses DATABASE_URL
sqlx migrate run
sqlx migrate info               # every line says installed; pending or "different checksum" fails the check
cargo sqlx prepare --check      # fails when .sqlx is stale
SQLX_OFFLINE=true cargo build   # compiles every query! macro with no database
cargo test
```

Add one failing case by hand: rename a column in a migration without updating the query, and `cargo sqlx prepare
--check` must fail. Connect for real in one test and assert `SELECT 1` through the same `PgPool` settings as production.

## Checklist

Check these points before you call Rust database code done.

- [ ] One `PgPool` per process, built once, with `acquire_timeout` and `max_connections` set on purpose.
- [ ] Every value bound; dynamic SQL only via `QueryBuilder` or a reviewed `AssertSqlSafe` with an allowlist.
- [ ] `.sqlx/` committed and `cargo sqlx prepare --check` runs in CI.
- [ ] Migrations embedded or run by sqlx-cli; concurrent index files carry `-- no-transaction`.
- [ ] Transactions retry on `40001` and `40P01` only; errors matched by SQLSTATE.
- [ ] `numeric` maps to `Decimal`, `timestamptz` to `DateTime<Utc>` or `OffsetDateTime`; no money in `f64`.
- [ ] TLS with `sslmode=verify-full` off the local machine; listeners and streams dropped before `pool.close()`.

## See also

Related skills in this library:

- `postgres-app-drivers`: the driver chooser across languages
- `postgres-connection-pooling`: pool sizes and PgBouncer
- `postgres-schema-migrations`: lock-safe DDL
- `postgres-transactions-locking`: isolation levels and retries
- `postgres-sql-patterns`: arrays with `unnest` and upserts

## Sources

- https://docs.rs/sqlx/0.9.0/sqlx/ and https://github.com/launchbadge/sqlx/blob/main/CHANGELOG.md (0.9.0 entries)
- https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md and `sqlx migrate add --help` (sqlx-cli 0.9.0)
- https://github.com/launchbadge/sqlx/blob/main/sqlx-core/src/config/reference.toml
- https://crates.io/crates/sqlx, /tokio-postgres, /deadpool-postgres, /diesel, /diesel-async, /sea-orm (versions, features)
- https://docs.rs/deadpool-postgres/0.14.2/ and https://docs.rs/tokio-postgres/0.7.18/
- https://diesel.rs/guides/getting-started.html and https://docs.rs/diesel-async/0.9.2/
- https://www.postgresql.org/docs/18/sql-createindex.html and https://www.postgresql.org/docs/18/errcodes-appendix.html
