---
title: tokio-postgres, deadpool-postgres, Diesel and SeaORM on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# tokio-postgres, deadpool-postgres, Diesel and SeaORM on PostgreSQL

This reference holds complete Rust programs for the three alternatives to SQLx: tokio-postgres with
deadpool-postgres (pipelining and binary COPY), Diesel 2.3 with diesel-async 0.9 (schema.rs, migrations, async
pool), and notes on SeaORM 2.0. Both programs ran against PostgreSQL 18.6 in October 2026.

## Contents

The sections of this reference on tokio-postgres, deadpool-postgres, Diesel and SeaORM:

1. tokio-postgres with deadpool-postgres: Cargo.toml
2. tokio-postgres program: pool, binary COPY, pipelining, transaction, SQLSTATE
3. deadpool-postgres recycling methods
4. Diesel 2.3 with diesel-async 0.9: setup and schema.rs
5. Diesel program: migrations, pool, upsert, transaction, errors
6. Diesel migrations that must run outside a transaction
7. Installing diesel_cli on macOS, Linux and Windows
8. SeaORM 2.0 on PostgreSQL

## tokio-postgres with deadpool-postgres: Cargo.toml

tokio-postgres 0.7 is the async driver under deadpool-postgres; type support is behind `with-*` features.

```toml
[dependencies]
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
tokio-postgres = { version = "0.7", features = ["with-chrono-0_4", "with-uuid-1", "with-serde_json-1"] }
deadpool-postgres = "0.14"
futures = "0.3"
chrono = "0.4"
```

## tokio-postgres program: pool, binary COPY, pipelining, transaction, SQLSTATE

This program builds a deadpool pool from `DATABASE_URL`, loads 10,000 rows with binary COPY, pipelines two prepared
queries on one client, runs a transaction and matches an error by SQLSTATE.

```rust
use deadpool_postgres::{Config, ManagerConfig, PoolConfig, RecyclingMethod, Runtime};
use futures::pin_mut;
use tokio_postgres::binary_copy::BinaryCopyInWriter;
use tokio_postgres::error::SqlState;
use tokio_postgres::types::Type;
use tokio_postgres::NoTls;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut cfg = Config::new();
    cfg.url = Some(std::env::var("DATABASE_URL")?);
    cfg.application_name = Some("ingest".into());
    cfg.manager = Some(ManagerConfig { recycling_method: RecyclingMethod::Fast });
    cfg.pool = Some(PoolConfig::new(10));
    let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls)?;      // NoTls only for local sockets

    let mut client = pool.get().await?;
    client.batch_execute(
        "CREATE TABLE IF NOT EXISTS readings (sensor int NOT NULL, at timestamptz NOT NULL, value float8 NOT NULL)",
    ).await?;

    // binary COPY: typed rows, no text parsing on the server
    let sink = client.copy_in("COPY readings (sensor, at, value) FROM STDIN (FORMAT binary)").await?;
    let writer = BinaryCopyInWriter::new(sink, &[Type::INT4, Type::TIMESTAMPTZ, Type::FLOAT8]);
    pin_mut!(writer);
    let now = chrono::Utc::now();
    for i in 0..10_000i32 {
        writer.as_mut().write(&[&(i % 10), &now, &(i as f64 * 0.5)]).await?;
    }
    let n = writer.finish().await?;
    println!("copied {n}");

    // pipelining: both queries go out before either answer is read
    let s1 = client.prepare_cached("SELECT count(*) FROM readings WHERE sensor = $1").await?;
    let s2 = client.prepare_cached("SELECT max(value) FROM readings WHERE sensor = $1").await?;
    let (a, b) = tokio::try_join!(client.query_one(&s1, &[&3i32]), client.query_one(&s2, &[&3i32]))?;
    println!("{} {}", a.get::<_, i64>(0), b.get::<_, f64>(0));

    // transaction: dropping it without commit rolls back
    let tx = client.transaction().await?;
    tx.execute("DELETE FROM readings WHERE sensor = $1", &[&9i32]).await?;
    tx.commit().await?;

    let err = client.execute("SELECT 1/0", &[]).await.unwrap_err();
    if err.code() == Some(&SqlState::DIVISION_BY_ZERO) { println!("22012"); }
    // retry codes: SqlState::T_R_SERIALIZATION_FAILURE (40001), SqlState::T_R_DEADLOCK_DETECTED (40P01)
    Ok(())
}
```

For TLS replace `NoTls` with a connector from `tokio-postgres-rustls` 0.14.0, `postgres-native-tls` 0.5.3 or
`postgres-openssl` 0.5.3. A tokio-postgres `Client` is not a pool: one client runs one query at a time on the wire
(pipelined), so share the deadpool `Pool`, not a single client.

## deadpool-postgres recycling methods

deadpool-postgres checks a connection when it returns to the pool, using the `RecyclingMethod` in `ManagerConfig`.

| Method | What runs on recycle | Use for |
|---|---|---|
| `Fast` (default) | `Client::is_closed()` only | most services |
| `Verified` | `is_closed()` and a test query | networks that drop links silently |
| `Clean` | instead of the test query: `CLOSE ALL`, `SET SESSION AUTHORIZATION DEFAULT`, `RESET ALL`, `UNLISTEN *`, `pg_advisory_unlock_all()`, `DISCARD TEMP`, `DISCARD SEQUENCES` (like `DISCARD ALL` but keeps prepared statements) | code that changes session state |
| `Custom(sql)` | your SQL | special cleanup |

## Diesel 2.3 with diesel-async 0.9: setup and schema.rs

Diesel's async support lives in diesel-async; with `default-features = false` and the `postgres_backend` feature,
Diesel itself needs no libpq because diesel-async talks to the server through tokio-postgres.

```toml
[dependencies]
diesel = { version = "2.3", default-features = false, features = ["postgres_backend", "chrono", "serde_json"] }
diesel-async = { version = "0.9", features = ["postgres", "deadpool", "migrations"] }
diesel_migrations = "2.3"
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
chrono = "0.4"
serde_json = "1"
```

The CLI creates the migrations folder and `diesel.toml`, and regenerates `src/schema.rs` after each migration run.

```bash
diesel setup                            # creates the database, migrations/ and diesel.toml
diesel migration generate create_posts  # migrations/<YYYY-MM-DD-HHMMSS-0000>_create_posts/{up,down}.sql
diesel migration run                    # applies and rewrites src/schema.rs ([print_schema] file in diesel.toml)
diesel migration redo                   # revert and re-run the latest: proves down.sql works
```

For a table with `id bigint GENERATED ALWAYS AS IDENTITY`, `body jsonb` and `created_at timestamptz`, the generated
`schema.rs` reads:

```rust
diesel::table! {
    posts (id) {
        id -> Int8,
        slug -> Text,
        title -> Text,
        body -> Jsonb,
        published -> Bool,
        created_at -> Timestamptz,
    }
}
```

## Diesel program: migrations, pool, upsert, transaction, errors

This program runs embedded migrations through `AsyncMigrationHarness`, builds a deadpool pool of
`AsyncPgConnection`s, upserts with `RETURNING`, runs a transaction with an async closure, and matches a unique
violation.

```rust
use chrono::{DateTime, Utc};
use diesel::prelude::*;
use diesel::result::{DatabaseErrorKind, Error as DieselError};
use diesel::upsert::excluded;
use diesel_async::pooled_connection::deadpool::Pool;
use diesel_async::pooled_connection::AsyncDieselConnectionManager;
use diesel_async::{AsyncConnection, AsyncMigrationHarness, AsyncPgConnection, RunQueryDsl};
use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};

mod schema;
use schema::posts;

const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

#[derive(Queryable, Selectable, Debug)]
#[diesel(table_name = posts, check_for_backend(diesel::pg::Pg))]
struct Post { id: i64, slug: String, title: String, body: serde_json::Value, published: bool, created_at: DateTime<Utc> }

#[derive(Insertable)]
#[diesel(table_name = posts)]
struct NewPost<'a> { slug: &'a str, title: &'a str, body: serde_json::Value }

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = std::env::var("DATABASE_URL")?;

    // the harness uses block_in_place: it needs the multi-threaded runtime
    let mut harness = AsyncMigrationHarness::new(AsyncPgConnection::establish(&url).await?);
    harness.run_pending_migrations(MIGRATIONS)?;
    drop(harness.into_inner());

    let pool = Pool::builder(AsyncDieselConnectionManager::<AsyncPgConnection>::new(url)).max_size(10).build()?;
    let mut conn = pool.get().await?;

    let p: Post = diesel::insert_into(posts::table)
        .values(&NewPost { slug: "hello", title: "Hello", body: serde_json::json!({"blocks": 1}) })
        .on_conflict(posts::slug)
        .do_update()
        .set(posts::title.eq(excluded(posts::title)))
        .returning(Post::as_returning())
        .get_result(&mut conn)
        .await?;
    println!("{p:?}");

    let published = conn
        .transaction::<_, DieselError, _>(async |conn| {
            diesel::update(posts::table.filter(posts::slug.eq("hello")))
                .set(posts::published.eq(true))
                .execute(conn)
                .await?;
            posts::table.filter(posts::published).count().get_result::<i64>(conn).await
        })
        .await?;
    println!("published {published}");

    match diesel::insert_into(posts::table)
        .values(&NewPost { slug: "hello", title: "x", body: serde_json::json!({}) })
        .execute(&mut conn)
        .await
    {
        Err(DieselError::DatabaseError(DatabaseErrorKind::UniqueViolation, info)) => {
            println!("unique violation on {:?}", info.constraint_name())       // Some("posts_slug_key")
        }
        other => println!("{other:?}"),
    }
    Ok(())
}
```

diesel-async 0.9 replaced the `scope_boxed()` closures of older releases with async closures (`async |conn| { ... }`);
code copied from older examples fails with `no method named scope_boxed`. `DatabaseErrorKind` also has
`SerializationFailure` for the `40001` retry.

## Diesel migrations that must run outside a transaction

Diesel runs every migration inside a transaction, so `CREATE INDEX CONCURRENTLY` fails with `cannot run inside a
transaction block`. A `metadata.toml` file in that migration's folder turns the transaction off for it alone.

```toml
# migrations/2026-10-28-140000-0000_posts_created_idx/metadata.toml
run_in_transaction = false
```

With it, `up.sql` can hold `CREATE INDEX CONCURRENTLY IF NOT EXISTS posts_created_at_idx ON posts (created_at);` and
`down.sql` the matching `DROP INDEX CONCURRENTLY IF EXISTS`. Keep one statement per such file: without a
transaction, a failure halfway leaves the earlier statements applied.

## Installing diesel_cli on macOS, Linux and Windows

diesel_cli links libpq for its Postgres support. Pick the install by what the machine has.

| Machine | Command |
|---|---|
| libpq and its headers installed (Debian/Ubuntu `libpq-dev`, Fedora `libpq-devel`) | `cargo install diesel_cli --no-default-features --features postgres` |
| no system libpq (common on macOS and Windows) | `cargo install diesel_cli --no-default-features --features postgres-bundled` |

The `postgres-bundled` feature builds libpq from source through `pq-sys`; it needs a C compiler (Xcode command line
tools on macOS, MSVC build tools on Windows). The first row was run on Debian in October 2026; the bundled build was
not run for this reference.

## SeaORM 2.0 on PostgreSQL

SeaORM 2.0.4 is an async ORM built on SQLx 0.9 and SeaQuery 1.0. Enable `sqlx-postgres` with one runtime feature,
such as `runtime-tokio-rustls`; `postgres-array` and `postgres-vector` add array and pgvector columns. Entities come
from the live schema with `sea-orm-cli generate entity`, writes go through an `ActiveModel`, and migrations live in
a separate migration crate. Because the connection is SQLx underneath, the SQLx rules hold: one connection pool per
process, timeouts in connect options, and retries keyed on SQLSTATE `40001` and `40P01`.
