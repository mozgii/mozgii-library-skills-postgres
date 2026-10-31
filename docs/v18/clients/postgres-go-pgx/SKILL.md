---
name: postgres-go-pgx
description: 'Builds Go services on PostgreSQL with pgx v5 in depth: a runnable pgxpool quickstart, pool configuration and its defaults, QueryExecMode and PgBouncer, CollectRows and RowToStructByName, batches, CopyFrom, LISTEN with WaitForNotification, pgtype and NUMERIC as decimal, query tracing, database/sql through pgx stdlib, sqlc generating typed code from SQL, goose and golang-migrate migrations, pgconn.PgError codes with retries, and context timeouts that really cancel. Use when writing Postgres code in Go, choosing between pgx and database/sql, setting up sqlc, "prepared statement already exists" behind PgBouncer, or scanning rows into structs.'
metadata:
  tags:
  - postgres
  - go
  - golang
  - pgx
  - pgxpool
  - sqlc
  - goose
  - golang-migrate
---

# PostgreSQL from Go with pgx v5

Use pgx v5 through `pgxpool` for new Go code: it speaks the PostgreSQL protocol natively (binary formats, `COPY`,
batches, `LISTEN`), and `database/sql` stays available on top of the same pool for libraries that need `*sql.DB`. Write
SQL in `.sql` files and let sqlc generate the Go; reach for an ORM only when a team already has one. The choice
across languages and the shared rules are in `postgres-app-drivers`. Detail:
[sqlc and migrations](references/sqlc-migrations.md), [query tracing](references/tracing.md).

## Step 0: read the Go and pgx versions in the project

pgx v4 and v5 have different import paths and APIs, so check the module file before writing code.

```bash
go version
go list -m github.com/jackc/pgx/v5 github.com/jackc/pgx/v4 2>/dev/null
grep -E 'pgx|sqlc|goose|migrate' go.mod
sqlc version 2>/dev/null; goose --version 2>/dev/null
```

## Choose pgx, database/sql or an ORM

Pick the thinnest layer that gives the types you need.

| Layer | Wins when | Loses when |
|---|---|---|
| pgx v5 with `pgxpool` | new code; `COPY`, batches, `LISTEN`, binary types | a library insists on `*sql.DB` |
| sqlc on pgx | SQL-first teams that want typed methods | queries are built dynamically at run time |
| `database/sql` through pgx stdlib | goose, golang-migrate, older libraries | you need `CopyFrom`, batches or `LISTEN` |
| GORM or ent | a team already on one, CRUD-heavy code | hand-tuned SQL and Postgres features |

## Quickstart: connect, query and close with pgxpool

This quickstart creates a module, adds pgx v5.11.0, and runs one parameterized query with a deadline. `go mod tidy`
after `go get` pulls the pool's own dependency (`puddle`); without it `go run` fails with `missing go.sum entry`.

```bash
mkdir pgx-quickstart && cd pgx-quickstart
go mod init example.com/quickstart
go get github.com/jackc/pgx/v5@v5.11.0
```

The program opens a pool, queries the server under a 10-second context, and closes the pool on exit.

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("pool: %v", err)
	}
	defer pool.Close()

	var now time.Time
	var version string
	err = pool.QueryRow(ctx, "SELECT now(), current_setting($1)", "server_version").Scan(&now, &version)
	if err != nil {
		log.Fatalf("query: %v", err)
	}
	fmt.Println(now.UTC().Format(time.RFC3339), version)
}
```

Run `go mod tidy && go run .` with `DATABASE_URL=postgres://app:secret@localhost:5432/app?sslmode=verify-full` (on
Windows PowerShell set `$env:DATABASE_URL` first). Current versions in October 2026: Go 1.27.3, pgx v5.11.0, sqlc
v1.31.1, goose v3.29.0, golang-migrate v4.20.1, shopspring/decimal v1.6.0.

## pgxpool configuration and its defaults

A pgxpool `Config` must come from `pgxpool.ParseConfig` and can then be changed. Pool settings also work as URL
parameters (`pool_max_conns=10`), and any URL parameter libpq does not know becomes a session setting
(`statement_timeout=30s`).

| Field (URL parameter) | Default | Advice |
|---|---|---|
| `MaxConns` (`pool_max_conns`) | greater of 4 or `runtime.NumCPU()` | set it from the connection budget (`postgres-connection-pooling`) |
| `MinIdleConns` (`pool_min_idle_conns`) | 0 | 2 or more to cut tail latency; better than `MinConns` for this |
| `MaxConnLifetime` (`pool_max_conn_lifetime`) | 1 hour | 30 min, with `MaxConnLifetimeJitter` so all do not close at once |
| `MaxConnIdleTime` (`pool_max_conn_idle_time`) | 30 minutes | 5 min behind a pooler |
| `HealthCheckPeriod` (`pool_health_check_period`) | 1 minute | keep |
| `ConnConfig.ConnectTimeout` (`connect_timeout`) | none | 5 s |

The block below builds a production pool with session settings, a tracer and a per-connection hook. It uses
`slowQueryTracer`, from [references/tracing.md](references/tracing.md).

```go
cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
if err != nil {
	return nil, err
}
cfg.MaxConns = 10
cfg.MinIdleConns = 2
cfg.MaxConnLifetime = 30 * time.Minute
cfg.MaxConnLifetimeJitter = 5 * time.Minute
cfg.MaxConnIdleTime = 5 * time.Minute
cfg.ConnConfig.ConnectTimeout = 5 * time.Second
cfg.ConnConfig.RuntimeParams["application_name"] = "orders-api"
cfg.ConnConfig.RuntimeParams["statement_timeout"] = "30s"
cfg.ConnConfig.Tracer = slowQueryTracer{min: 200 * time.Millisecond}
cfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
	pgxdecimal.Register(c.TypeMap()) // numeric <-> decimal.Decimal
	return nil
}
pool, err := pgxpool.NewWithConfig(ctx, cfg)
```

`pool.Stat()` reports `TotalConns`, `IdleConns`, `AcquireCount` and `EmptyAcquireCount`; export them as metrics.
pgx defaults to `sslmode=prefer` like libpq, which falls back to plain text: set `sslmode=verify-full` off localhost.

## QueryExecMode and PgBouncer

pgx QueryExecMode decides how a query reaches the server. The default `cache_statement` prepares each statement once
per connection under a generated name, which needs session state; set the mode in the URL
(`default_query_exec_mode=exec`) or per query by passing the mode as the first argument.

| Mode | Round trips | Named prepared statements | Use |
|---|---|---|---|
| `cache_statement` (default) | 1 after the first | yes | direct connections; PgBouncer 1.21+ with `max_prepared_statements` above 0 |
| `cache_describe` | 1 after the first | no | schema changes often invalidate statements |
| `describe_exec` | 2 | unnamed only | may break when a pooler switches connections between round trips |
| `exec` | 1 | no, text parameters | transaction poolers without prepared statement support |
| `simple_protocol` | 1 | no, client-side quoting | only for proxies that lack the extended protocol |

`exec` and `simple_protocol` guess parameter types from Go types: a `[]byte` becomes `bytea`, and JSON must be passed
as `string`. After a migration changes a table, a cached `SELECT *` can fail once with
`cached plan must not change result type`; name columns instead of `*`.

## Scanning rows into structs with CollectRows

pgx `CollectRows` with `RowToStructByName` maps columns to struct fields by `db` tag and closes the rows. Pointers
receive `NULL` as `nil`; `CollectExactlyOneRow` returns `pgx.ErrNoRows` or `pgx.ErrTooManyRows`.

```go
type Order struct {
	ID        int64           `db:"id"`
	Customer  string          `db:"customer"`
	Total     decimal.Decimal `db:"total"`
	Note      *string         `db:"note"`
	CreatedAt time.Time       `db:"created_at"`
}

rows, _ := pool.Query(ctx, `SELECT id, customer, total, note, created_at FROM orders WHERE customer = $1`, c)
orders, err := pgx.CollectRows(rows, pgx.RowToStructByName[Order])

var count int64
err = pool.QueryRow(ctx, `SELECT count(*) FROM orders WHERE id = ANY($1)`, []int64{1, 2, 3}).Scan(&count)
```

Ignoring the error from `pool.Query` is safe here: `CollectRows` reports it. `RowToStructByName` needs every column
to have a field and every field a column. `RowToStructByNameLax` allows a struct field with no column, which stays at
its zero value; a selected column with no field is an error in both (`struct doesn't have corresponding row field`,
pgx 5.11.0).

## pgtype and NUMERIC as decimal

pgx pgtype maps PostgreSQL types to Go. `numeric` scans into `pgtype.Numeric` or a `string` by default, never into
`float64` without loss. Register `github.com/jackc/pgx-shopspring-decimal` in `AfterConnect` to read and write
`decimal.Decimal`. Other mappings: `timestamptz` to `time.Time` (UTC instant), `jsonb` to any struct through
`encoding/json`, arrays to slices, `uuid` to `[16]byte` or `pgtype.UUID`, and `pgtype.Text` with `Valid` for
explicit `NULL`.

## Batches and CopyFrom for many rows

A pgx `Batch` sends queued statements in one network round trip; `CopyFrom` uses binary `COPY` and is the fastest way
to insert many rows.

```go
b := &pgx.Batch{}
b.Queue(`UPDATE orders SET note = 'vip' WHERE customer = $1`, "c1")
b.Queue(`SELECT count(*) FROM orders WHERE note = 'vip'`).QueryRow(func(r pgx.Row) error { return r.Scan(&count) })
err = pool.SendBatch(ctx, b).Close() // Close runs the callbacks and returns the first error

rows := [][]any{{"c1", decimal.RequireFromString("9.99")}, {"c2", decimal.RequireFromString("5.00")}}
n, err := pool.CopyFrom(ctx, pgx.Identifier{"orders"}, []string{"customer", "total"}, pgx.CopyFromRows(rows))
```

A batch runs in one implicit transaction unless it contains `BEGIN`/`COMMIT`: one failing statement rolls back the
others. In the default exec mode every statement is prepared before any runs, so a `CREATE TABLE` and a query on it
in the same batch fail. `CopyFrom` fails on any constraint violation and loads nothing; use a staging table plus
`INSERT ... ON CONFLICT` for upserts.

## LISTEN with WaitForNotification

pgx `WaitForNotification` blocks on one connection until a `NOTIFY` arrives or the context ends. Use a dedicated
`pgx.Connect` connection (or `pool.Acquire` held for the listener's life), never a pooled query.

```go
lc, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
if err != nil {
	return err
}
defer lc.Close(ctx)
if _, err := lc.Exec(ctx, `LISTEN order_paid`); err != nil {
	return err
}
for {
	n, err := lc.WaitForNotification(ctx)
	if err != nil {
		return err // reconnect, LISTEN again, then re-read missed work from a table
	}
	handle(n.Channel, n.Payload)
}
```

## Transactions, PgError codes and retries

pgx `BeginTxFunc` commits when the function returns nil and rolls back otherwise. Errors from the server are
`*pgconn.PgError` with `Code` (SQLSTATE), `ConstraintName`, `TableName` and `Detail`; `github.com/jackc/pgerrcode`
names the codes.

```go
func inTx(ctx context.Context, pool *pgxpool.Pool, opts pgx.TxOptions, fn func(pgx.Tx) error) error {
	for attempt := 1; ; attempt++ {
		err := pgx.BeginTxFunc(ctx, pool, opts, fn)
		var pgErr *pgconn.PgError
		if err == nil || !errors.As(err, &pgErr) || attempt == 4 ||
			(pgErr.Code != pgerrcode.SerializationFailure && pgErr.Code != pgerrcode.DeadlockDetected) {
			return err
		}
		select {
		case <-time.After(time.Duration(attempt*attempt*20+rand.IntN(30)) * time.Millisecond):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}
```

Inside `fn`, use the `tx` argument, never `pool`. Map `23505` (`UniqueViolation`) to a conflict response and `23503`
(`ForeignKeyViolation`) to a bad reference; let everything else surface.

## Context timeouts that cancel queries

Every pgx call takes a `context.Context`; when it ends, pgx stops waiting. By default pgx sets a deadline on the
socket and closes that connection (the error matches `errors.Is(err, context.DeadlineExceeded)` and
`pgconn.Timeout(err)`). To ask the server to cancel and keep the connection, install the cancel-request handler:

```go
cfg.ConnConfig.BuildContextWatcherHandler = func(c *pgconn.PgConn) ctxwatch.Handler {
	return &pgconn.CancelRequestContextWatcherHandler{Conn: c, DeadlineDelay: time.Second}
}
```

With it the error is SQLSTATE `57014` (`query_canceled`). Keep a server-side `statement_timeout` as well: a context
only protects callers that set one.

## Query tracing and logging

pgx calls a `QueryTracer` (`TraceQueryStart`, `TraceQueryEnd`) for every query; `BatchTracer`, `CopyFromTracer`,
`PrepareTracer` and `ConnectTracer` are optional extras. `github.com/jackc/pgx/v5/tracelog` adapts any logger,
`github.com/jackc/pgx/v5/multitracer` combines tracers, and `github.com/exaring/otelpgx` (v0.13.0) emits
OpenTelemetry spans. Log SQL text and timings; never log argument values, which hold user data.

`slowQueryTracer`, a `QueryTracer` that logs statements slower than a limit, is written out in
[references/tracing.md](references/tracing.md).

## database/sql through pgx stdlib

`github.com/jackc/pgx/v5/stdlib` registers the driver name `pgx` for `sql.Open("pgx", url)`, and
`stdlib.OpenDBFromPool(pool)` gives a `*sql.DB` that borrows from an existing pgxpool. Use it for goose,
golang-migrate's library form, or an ORM; keep native pgx for your own queries, since `database/sql` loses
`CopyFrom`, batches and `LISTEN`.

## sqlc: typed Go from SQL files

sqlc reads the schema (it understands goose and golang-migrate files) and annotated queries, checks them, and writes
Go methods. With `sql_package: "pgx/v5"` the code runs on pgxpool. The full config, overrides and CI commands are in
[sqlc and migrations](references/sqlc-migrations.md).

```sql
-- name: ListCustomersByIDs :many
SELECT id, email FROM customers WHERE id = ANY(@ids::bigint[]) ORDER BY id;

-- name: AddCredit :execrows
UPDATE customers SET credit = credit + sqlc.arg(amount) WHERE id = sqlc.arg(id);

-- name: CopyCustomers :copyfrom
INSERT INTO customers (email) VALUES ($1);
```

## Gotchas

These are the Go and pgx failures seen most often, each with its symptom, cause and fix.

1. **`missing go.sum entry ... puddle`.** `go get` added pgx but not pgxpool's dependency. Run `go mod tidy`.
2. **`prepared statement "stmtcache_..." already exists` or `does not exist`.** A transaction pooler without prepared
   statement support. Use PgBouncer 1.21+ with `max_prepared_statements`, or `default_query_exec_mode=exec`.
3. **`conn busy`.** Rows were not closed before the next query on the same connection or `tx`. Use `CollectRows`, or
   `defer rows.Close()` and check `rows.Err()`.
4. **The pool runs out under load.** A `Rows` was never closed, or a goroutine held a `pool.Acquire` conn. Watch
   `EmptyAcquireCount` and release in `defer`.
5. **A query keeps running after the HTTP request ended.** No context deadline, or the default handler closed the
   socket while the server kept working. Pass request contexts and set `statement_timeout`.
6. **Money is off by a cent.** `numeric` was scanned into `float64`. Use `decimal.Decimal` or `pgtype.Numeric`.
7. **`Dirty database version N. Fix and force version.`** A golang-migrate migration failed half way. Repair by hand,
   then `migrate force N`.

## Verify Go database code against a real server

These checks use the standard tools plus a real PostgreSQL, because the pool, the exec mode and `COPY` have no useful
mock.

```bash
go vet ./... && go test -race ./...               # with DATABASE_URL pointing at a scratch database
sqlc diff                                         # generated code matches the queries
sqlc vet                                          # the queries pass the configured rules
```

Run one test through the real pooler URL if you deploy behind one: it proves the exec mode. Set a 50 ms context on
`SELECT pg_sleep(1)` and expect an error that matches `context.DeadlineExceeded`, then a clean query on the same pool.

## Checklist

Check these points before calling Go database code done.

- [ ] One `pgxpool.Pool` per process, built by `ParseConfig`, with `MaxConns`, lifetimes and `ConnectTimeout` set.
- [ ] `sslmode=verify-full` off localhost; credentials from the environment or a secret store.
- [ ] Every call takes a context with a deadline; `statement_timeout` set on the role or connection.
- [ ] Rows closed (`CollectRows` or `defer rows.Close()`), `rows.Err()` checked.
- [ ] Transactions use `tx` and retry `40001` and `40P01` only.
- [ ] Exec mode matches the pooler; `numeric` maps to a decimal type.
- [ ] Bulk inserts use `CopyFrom`; migrations run once per deploy under a lock.

## Anti-patterns in Go database code

| Do not | Do this instead |
|---|---|
| call `pgxpool.New` per request | one pool per process |
| use `context.Background()` in request paths | the request context, with a deadline |
| leave `Rows` open across another query | `CollectRows`, or `defer rows.Close()` |
| use `pool` inside `BeginTxFunc` | the `tx` argument |
| log query arguments in a tracer | SQL text and timings only |
| scan `numeric` into `float64` | `decimal.Decimal` or `pgtype.Numeric` |

## See also

- `postgres-app-drivers`: the rules shared by every language.
- `postgres-connection-pooling`: pool budget and PgBouncer.
- `postgres-transactions-locking`: what to retry and why.
- `postgres-schema-migrations`: safe DDL for goose and golang-migrate files.
- `postgres-bulk-load-etl`: staging tables behind `CopyFrom`.

## Sources

- https://pkg.go.dev/github.com/jackc/pgx/v5 and `go doc` on pgx v5.11.0 (pgxpool.ParseConfig, pgxpool.Config, QueryExecMode, pgconn.ParseConfig, CancelRequestContextWatcherHandler)
- https://github.com/jackc/pgx/wiki and the pgx v5 source (pgconn/config.go default context handler)
- https://docs.sqlc.dev/en/stable/reference/config.html, /reference/query-annotations.html, `sqlc --help` (v1.31.1)
- https://github.com/pressly/goose (README, provider options, lock package v3.29.0)
- https://github.com/golang-migrate/migrate (GETTING_STARTED.md, database/postgres/README.md)
- https://www.postgresql.org/docs/18/errcodes-appendix.html, /sql-notify.html, /libpq-connect.html
- https://proxy.golang.org module versions, read 2026-10-28
