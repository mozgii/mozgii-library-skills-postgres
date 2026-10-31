---
title: SQLx dynamic SQL, COPY, LISTEN and SQLSTATE errors
author: MOZGII, Inc.
lang: en
---

# SQLx dynamic SQL, COPY, LISTEN and SQLSTATE errors

This reference covers four SQLx 0.9 tasks on PostgreSQL that need more code than the skill holds: dynamic SQL under
the `SqlSafeStr` rule, bulk loading with COPY and UNNEST, LISTEN and NOTIFY with `PgListener`, and matching errors by
SQLSTATE. Every snippet ran against PostgreSQL 18.6 in October 2026.

## Contents

The sections of this reference on SQLx dynamic SQL, COPY, LISTEN and SQLSTATE errors:

1. Dynamic SQL in SQLx 0.9 with AssertSqlSafe and QueryBuilder
2. Bulk loading with COPY and UNNEST in SQLx
3. LISTEN and NOTIFY with SQLx PgListener
4. SQLSTATE error handling in Rust

## Dynamic SQL in SQLx 0.9 with AssertSqlSafe and QueryBuilder

SQLx 0.9 query functions accept only `&'static str` or `AssertSqlSafe(...)`: a `String` built with `format!` no
longer compiles. Wrap it only after the variable parts come from an allowlist, and still bind every value.

```rust
let col = match sort { "email" => "email", "total" => "total", _ => "placed_at" };   // allowlist
let sql = format!("SELECT id FROM orders ORDER BY {col} LIMIT $1");
let ids: Vec<Uuid> = sqlx::query_scalar(sqlx::AssertSqlSafe(sql)).bind(50_i64).fetch_all(&pool).await?;
```

`sqlx::QueryBuilder` builds variable `WHERE` clauses and multi-row `VALUES` with `push_bind`, which binds instead of
concatenating.

## Bulk loading with COPY and UNNEST in SQLx

`PgConnection::copy_in_raw` streams rows with `COPY ... FROM STDIN`; it is the fastest load path and needs a single
connection, not the pool.

```rust
let mut conn = pool.acquire().await?;
let mut copy = conn.copy_in_raw("COPY orders (email, total) FROM STDIN WITH (FORMAT csv)").await?;
copy.send(b"a@x.example,10.50\nb@x.example,4.00\n".as_slice()).await?;
let rows: u64 = copy.finish().await?;       // abort("reason") cancels the COPY
```

For a few thousand rows with an upsert, bind arrays and `UNNEST` them in one statement:
`INSERT INTO t (a, b) SELECT * FROM UNNEST($1::text[], $2::numeric[]) ON CONFLICT (a) DO UPDATE SET b = EXCLUDED.b`.
For binary COPY with typed rows use tokio-postgres's `BinaryCopyInWriter`
([tokio-postgres-diesel.md](tokio-postgres-diesel.md)).

## LISTEN and NOTIFY with SQLx PgListener

`PgListener` holds one dedicated connection, re-subscribes after it reconnects, and yields `PgNotification`s.

```rust
let mut listener = sqlx::postgres::PgListener::connect_with(&pool).await?;
listener.listen("jobs").await?;
loop {
    let n = listener.recv().await?;           // n.channel(), n.payload(), n.process_id()
    handle(n.payload()).await;
}
```

A listener made with `connect_with(&pool)` holds a connection of that pool, and `pool.close()` waits until every
connection is returned: drop the listener before closing the pool. Notifications sent while it was reconnecting are
lost, so treat a notification as a wake-up and re-read the table. Listen on a direct connection, not through a
transaction-mode pooler.

## SQLSTATE error handling in Rust

Branch on the five-character SQLSTATE, never on the English message. SQLx exposes it through
`err.as_database_error()`; tokio-postgres through `err.code()` compared with `SqlState` constants.

```rust
if let Some(db) = err.as_database_error() {
    match db.code().as_deref() {
        Some("23505") => return Err(AppError::Conflict(db.constraint().unwrap_or_default().to_owned())),
        Some("40001" | "40P01") => { /* retry the whole transaction */ }
        Some("57014") => { /* statement_timeout cancelled it */ }
        _ => {}
    }
}
```

`db.is_unique_violation()`, `is_foreign_key_violation()` and `is_check_violation()` are shortcuts. In Diesel, match
`Error::DatabaseError(DatabaseErrorKind::UniqueViolation, info)` and read `info.constraint_name()`.
