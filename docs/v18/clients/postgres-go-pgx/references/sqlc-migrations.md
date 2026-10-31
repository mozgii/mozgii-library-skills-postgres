---
title: sqlc, goose and golang-migrate for Go on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# sqlc, goose and golang-migrate for Go on PostgreSQL

This reference sets up sqlc to generate typed pgx v5 code from SQL, and runs schema migrations with goose or
golang-migrate. Everything here ran on PostgreSQL 18.6 with sqlc v1.31.1, goose v3.29.0, golang-migrate v4.20.1 and
pgx v5.11.0. Lock and backfill rules for the migration SQL itself are in `postgres-schema-migrations`.

## Contents

The sections of this reference on sqlc and Go migrations:

1. sqlc project layout and sqlc.yaml
2. sqlc query annotations and parameters
3. Running sqlc in CI
4. goose migrations with the Provider and an advisory lock
5. golang-migrate files, the CLI and dirty versions
6. Choosing between goose and golang-migrate

## sqlc project layout and sqlc.yaml

sqlc needs three things: the schema (the migration folder works), the query files, and a `sqlc.yaml`. Install it with
`go install github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1`, from a release binary, or run the
`sqlc/sqlc:1.31.1` container. This config generates pgx v5 code with decimals and `time.Time`:

```yaml
version: "2"
sql:
  - engine: "postgresql"
    schema: "migrations"
    queries: "queries"
    gen:
      go:
        package: "db"
        out: "internal/db"
        sql_package: "pgx/v5"
        emit_json_tags: true
        emit_pointers_for_null_types: true
        overrides:
          - db_type: "pg_catalog.numeric"
            go_type: "github.com/shopspring/decimal.Decimal"
          - db_type: "timestamptz"
            go_type: "time.Time"
```

- Without the `timestamptz` override, pgx v5 output uses `pgtype.Timestamptz`.
- An override applies to `NOT NULL` columns; add a second entry with `nullable: true` for nullable ones.
- `emit_pointers_for_null_types` makes nullable columns `*string`, `*int64` instead of `pgtype.Text`.
- The `numeric` override needs `pgxdecimal.Register` in the pool's `AfterConnect` so pgx can encode the type.

## sqlc query annotations and parameters

Each query starts with `-- name: <Method> :<kind>`. The kind sets the return shape; `:copyfrom` and the `:batch*`
kinds need `sql_package: pgx/v5`.

| Kind | Returns |
|---|---|
| `:one` | one struct, `pgx.ErrNoRows` when none |
| `:many` | a slice |
| `:exec` | only an error |
| `:execrows` | rows affected |
| `:copyfrom` | rows copied, through `CopyFrom` |
| `:batchexec`, `:batchmany`, `:batchone` | results of a `pgx.Batch` |

Parameters are `$1`, or named with `@name` or `sqlc.arg(name)`; `sqlc.narg(name)` makes a nullable one. An array
parameter needs a cast, `= ANY(@ids::bigint[])`, so sqlc knows its type. These queries generate `GetCustomer`,
`ListCustomersByIDs(ctx, []int64)`, `AddCredit` and `CopyCustomers(ctx, []string)`:

```sql
-- name: GetCustomer :one
SELECT * FROM customers WHERE id = $1;

-- name: ListCustomersByIDs :many
SELECT id, email FROM customers WHERE id = ANY(@ids::bigint[]) ORDER BY id;

-- name: AddCredit :execrows
UPDATE customers SET credit = credit + sqlc.arg(amount) WHERE id = sqlc.arg(id);

-- name: CopyCustomers :copyfrom
INSERT INTO customers (email) VALUES ($1);
```

The generated `db.New(pool)` takes a pool, a connection or a transaction; inside `pgx.BeginFunc` use
`q.WithTx(tx)`. `SELECT *` in a sqlc query is expanded to the column list at generate time, so it is safe there.

## Running sqlc in CI

sqlc can prove in CI that generated code matches the SQL and that queries still compile against the schema.

```bash
sqlc compile     # parse and type-check schema and queries
sqlc vet         # run vet rules from sqlc.yaml
sqlc diff        # non-zero exit when generated files differ from what generate would write
```

Run `sqlc diff` after migrations change; a stale generated file is a build failure, not a runtime surprise.

## goose migrations with the Provider and an advisory lock

goose reads `NNNNN_name.sql` files with `-- +goose Up` and `-- +goose Down` sections and records versions in
`goose_db_version`. A file starting with `-- +goose NO TRANSACTION` runs outside a transaction, which
`CREATE INDEX CONCURRENTLY` needs.

```sql
-- +goose NO TRANSACTION
-- +goose Up
CREATE INDEX CONCURRENTLY IF NOT EXISTS customers_created_at_idx ON customers (created_at);

-- +goose Down
DROP INDEX CONCURRENTLY IF EXISTS customers_created_at_idx;
```

The Provider API runs embedded migrations under a Postgres session advisory lock, so two replicas starting together
do not migrate twice. It needs a `*sql.DB`, which `stdlib.OpenDBFromPool` provides.

```go
//go:embed migrations/*.sql
var migrations embed.FS

func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer sqlDB.Close()
	fsys, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return err
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, sqlDB, fsys, goose.WithSessionLocker(locker))
	if err != nil {
		return err
	}
	_, err = provider.Up(ctx)
	return err
}
```

The CLI (`go install github.com/pressly/goose/v3/cmd/goose@v3.29.0`) reads `GOOSE_DRIVER=postgres`,
`GOOSE_DBSTRING` and `GOOSE_MIGRATION_DIR` from the environment: `goose status`, `goose up`, `goose create add_x sql`.
Run migrations on a direct connection, not through a transaction pooler, since the session lock needs a session.

## golang-migrate files, the CLI and dirty versions

golang-migrate uses a pair of files per version, `000001_widgets.up.sql` and `000001_widgets.down.sql`, and records
`version` and `dirty` in `schema_migrations`. This runs the CLI from its container:

```bash
docker run --rm -v "$PWD/migrations:/migrations" migrate/migrate:v4.20.1 \
  -path=/migrations -database "postgres://app:secret@db:5432/app?sslmode=verify-full" up
```

- A failed migration sets `dirty = true` and blocks every later run with `Dirty database version N. Fix and force
  version.` Check what was applied, repair by hand, then `migrate ... force N`.
- The postgres driver takes options in the URL: `x-migrations-table`, `x-statement-timeout`, `x-multi-statement`.
- A file is not wrapped in a transaction for you: put `BEGIN;` and `COMMIT;` in the file when it has several
  statements that must apply together.

## Choosing between goose and golang-migrate

Both are maintained and both work with sqlc. Pick goose for one file per version, Go-coded migrations, embedded files
and a built-in advisory lock through the Provider; pick golang-migrate when the team wants separate up and down files
and the same tool for many databases. Either way, run migrations as a separate deploy step, not on every replica's
start, and never edit a file that has been applied.
