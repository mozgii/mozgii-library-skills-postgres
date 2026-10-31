---
title: PostgreSQL from Go, Java, .NET and Rust
author: MOZGII, Inc.
lang: en
---

# PostgreSQL from Go, Java, .NET and Rust

This reference shows a correct pool, a parameterized query and a transaction for the main PostgreSQL drivers in Go,
Java, .NET and Rust.

## Contents

The sections of this reference on postgreSQL from Go, Java, .NET and Rust:

1. Go with pgx v5 and pgxpool
2. Java with PgJDBC and HikariCP
3. .NET with Npgsql
4. Rust with SQLx

## Go with pgx v5 and pgxpool

pgx is the standard Go driver; use its native interface with `pgxpool` rather than `database/sql` unless a library
requires the latter.

```go
cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))   // ...?sslmode=verify-full&pool_max_conns=10
if err != nil { return err }
cfg.MaxConns = 10
cfg.MaxConnIdleTime = 30 * time.Second
cfg.ConnConfig.RuntimeParams["application_name"] = "app-api"
cfg.ConnConfig.RuntimeParams["statement_timeout"] = "30000"
pool, err := pgxpool.NewWithConfig(ctx, cfg)
if err != nil { return err }
defer pool.Close()

var email string
err = pool.QueryRow(ctx, "SELECT email FROM app.customers WHERE id = $1", id).Scan(&email)
if errors.Is(err, pgx.ErrNoRows) { /* not found */ }

err = pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{IsoLevel: pgx.Serializable}, func(tx pgx.Tx) error {
    _, err := tx.Exec(ctx, "UPDATE app.stock SET qty = qty - 1 WHERE sku = $1", sku)
    return err
})
var pgErr *pgconn.PgError
if errors.As(err, &pgErr) && pgErr.Code == "40001" { /* retry */ }
```

- `pgx.CollectRows(rows, pgx.RowToStructByName[Customer])` scans into structs.
- sqlc generates typed Go functions from `.sql` files and works on top of pgx: queries stay plain SQL.
- Behind an old pooler, set `default_query_exec_mode=exec` in the connection string.

## Java with PgJDBC and HikariCP

PgJDBC is the JDBC driver; HikariCP is the standard pool, and Spring Boot uses it by default.

```java
HikariConfig cfg = new HikariConfig();
cfg.setJdbcUrl("jdbc:postgresql://db.internal:5432/app?sslmode=verify-full&ApplicationName=app-api");
cfg.setUsername(System.getenv("DB_USER"));
cfg.setPassword(System.getenv("DB_PASSWORD"));
cfg.setMaximumPoolSize(10);
cfg.setConnectionTimeout(5_000);
cfg.addDataSourceProperty("reWriteBatchedInserts", "true");   // turns batches into multi-row inserts
HikariDataSource ds = new HikariDataSource(cfg);

try (Connection c = ds.getConnection()) {
  c.setAutoCommit(false);
  try (PreparedStatement ps = c.prepareStatement("UPDATE app.stock SET qty = qty - 1 WHERE sku = ?")) {
    ps.setString(1, sku);
    ps.executeUpdate();
    c.commit();
  } catch (SQLException e) {
    c.rollback();
    if ("40001".equals(e.getSQLState())) { /* retry */ }
    throw e;
  }
}
```

- Hibernate: use `GenerationType.SEQUENCE` or `IDENTITY` with a `bigint` identity column; set
  `hibernate.jdbc.batch_size` and `order_inserts` for batch writes; map `timestamptz` to `Instant` or
  `OffsetDateTime`.
- Behind an old pooler: `prepareThreshold=0` in the URL.

## .NET with Npgsql

Npgsql is the ADO.NET driver and the base of the EF Core provider. Create one `NpgsqlDataSource` per application.

```csharp
var builder = new NpgsqlDataSourceBuilder(
    "Host=db.internal;Database=app;Username=app_api;SSL Mode=VerifyFull;Maximum Pool Size=10;Application Name=app-api");
builder.ConnectionStringBuilder.Password = Environment.GetEnvironmentVariable("DB_PASSWORD");
await using var dataSource = builder.Build();

await using var cmd = dataSource.CreateCommand("SELECT email FROM app.customers WHERE id = $1");
cmd.Parameters.AddWithValue(id);
var email = (string?)await cmd.ExecuteScalarAsync();

await using var conn = await dataSource.OpenConnectionAsync();
await using var tx = await conn.BeginTransactionAsync(System.Data.IsolationLevel.Serializable);
// ... commands with Transaction = tx ...
await tx.CommitAsync();
```

- Npgsql maps `timestamptz` to `DateTime` with `Kind=Utc` and refuses non-UTC values for it; use UTC everywhere.
- EF Core: `UseNpgsql(dataSource)`; `EnableRetryOnFailure()` retries transient errors; for `Serializable` retries,
  catch `PostgresException` with `SqlState == "40001"`.

## Rust with SQLx

SQLx is an async, pure-Rust driver whose `query!` macros check SQL against a database at compile time.

```rust
let pool = sqlx::postgres::PgPoolOptions::new()
    .max_connections(10)
    .acquire_timeout(std::time::Duration::from_secs(5))
    .connect(&std::env::var("DATABASE_URL")?)
    .await?;

let email: Option<String> = sqlx::query_scalar("SELECT email FROM app.customers WHERE id = $1")
    .bind(id)
    .fetch_optional(&pool)
    .await?;

let mut tx = pool.begin().await?;
sqlx::query("UPDATE app.stock SET qty = qty - 1 WHERE sku = $1").bind(&sku).execute(&mut *tx).await?;
tx.commit().await?;            // dropping tx without commit rolls back
```

- `cargo sqlx prepare` stores query metadata so CI builds without a live database (`SQLX_OFFLINE=true`).
- `sqlx migrate run` applies files from `migrations/`; the same lock and expand-contract rules apply.
- tokio-postgres with `deadpool-postgres` is the lower-level alternative.
