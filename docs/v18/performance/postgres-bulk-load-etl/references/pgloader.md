---
title: Migrating databases to PostgreSQL with pgloader
author: MOZGII, Inc.
lang: en
---

# Migrating databases to PostgreSQL with pgloader

pgloader moves a whole MySQL, MariaDB, SQLite or SQL Server database (and CSV, fixed-width or dBase files) into
PostgreSQL in one run: it reads the source catalog, creates tables, streams rows with `COPY`, then builds indexes
and foreign keys and resets sequences. This reference covers pgloader 3.6.10, tested from the
`ghcr.io/dimitri/pgloader` image against a `postgres:18` container (PostgreSQL 18.6) with a SQLite source.

## Contents

The sections of this reference on pgloader:

1. Installing pgloader on Linux, macOS, Windows and Docker
2. One-line migrations
3. Load files: WITH, SET and CAST
4. Type casts that need care
5. Checks after a migration

## Installing pgloader on Linux, macOS, Windows and Docker

pgloader 3.6.10 is the stable line, written in Common Lisp. Version 4 is a Java 21 rewrite that accepts the same
load files; it is published only as a `v4-dev` JAR, so treat it as a preview.

| OS | Install |
|---|---|
| Debian, Ubuntu | `sudo apt install pgloader` (the PGDG repository carries 3.6.10) |
| macOS | `brew install pgloader`, or the Docker image |
| Windows | the Docker image (Docker Desktop), or WSL with the Debian package |
| Docker | `ghcr.io/dimitri/pgloader:latest`; amd64 only, so Apple silicon needs `--platform linux/amd64` |

This shell command runs the image against a load file in the current folder; the container must reach both
databases, here over a Docker network.

```bash
docker run --rm --platform linux/amd64 --network migrate-net -v "$PWD":/data \
  ghcr.io/dimitri/pgloader:latest pgloader /data/shop.load
```

pgloader 3.6.10 logged in to PostgreSQL 18's default `scram-sha-256` authentication without extra settings.

## One-line migrations

With source and target URIs only, pgloader uses its default casts and options; for MySQL the default `WITH` is `no
truncate, create tables, include drop, create indexes, reset sequences, foreign keys, downcase identifiers,
uniquify index names`.

```bash
createdb shop
pgloader mysql://app@mysql.example/shop postgresql://app@pg.example/shop
pgloader mssql://app@mssql.example/shop postgresql://app@pg.example/shop
pgloader ./shop.db postgresql:///shop                                         # SQLite file
```

When the target URI has no password, pgloader uses the `PGPASSWORD` environment variable; prefer that, or a load
file readable only by you, to a password on the command line, where other local users can see it.

## Load files: WITH, SET and CAST

A load file makes the migration repeatable: options, PostgreSQL settings for the load sessions, casting rules and
SQL to run before and after. This file was run against PostgreSQL 18.6 and loaded 21,000 rows in 0.2 s.

```text
LOAD DATABASE
  FROM sqlite:///data/shop.db
  INTO postgresql://postgres:<password>@pg18:5432/shop

WITH include drop, create tables, create indexes, reset sequences,
     workers = 4, concurrency = 1, batch rows = 10000

SET work_mem to '64MB', maintenance_work_mem to '512MB'

CAST type real to numeric drop typemod using float-to-string,
     column orders.placed_at to timestamptz,
     column customers.created_at to timestamptz;
```

- `include drop` drops target tables first; leave it out when loading into an existing schema, and use `data
  only` to skip DDL.
- For MySQL, tables land in a schema named after the MySQL database; `ALTER SCHEMA 'shop' RENAME TO 'public'` in
  the load file moves them. `quote identifiers` keeps mixed-case names, which the application must then quote.
- MySQL zero dates (`0000-00-00`) become NULL by default; the `zero-dates-to-null` transform does this per cast.

## Type casts that need care

Default casts keep the data loadable but not always the best PostgreSQL type. In the SQLite test, the defaults
produced these, and each needed a decision.

| Source | Default target | Problem | Cast used |
|---|---|---|---|
| SQLite `REAL` | `real` (4-byte float) | about 7 significant digits; money loses cents | `type real to numeric drop typemod using float-to-string` |
| SQLite `TEXT` holding dates | `text` | no date arithmetic or range indexes | `column t.c to timestamptz` |
| `INTEGER PRIMARY KEY` | `bigint` | none | keep |
| index names | `idx_16390_public.orders_pkey` | names carry an OID and a dot | rename after the load |

`CAST type real to numeric` without `using float-to-string` failed every row with `invalid input syntax for type
numeric: "1.5d0"`: pgloader printed the value in Lisp notation. The table stayed empty while the summary still
reported other tables as loaded, so always read the error count per table.

## Checks after a migration

A migration is done when the data matches, not when pgloader exits. Compare row counts and sums per table, run
`ANALYZE`, and review types, constraints and sequence positions.

```sql
SELECT count(*), sum(total), min(placed_at) FROM orders;
SELECT conrelid::regclass AS table_name, conname, contype FROM pg_constraint
WHERE connamespace = 'public'::regnamespace ORDER BY 1, 2;
SELECT sequencename, last_value FROM pg_sequences;
ANALYZE;
```

The test above returned `20000 | 300015000.0 | 2026-02-01 12:00:00+00`, matching the SQLite source.

## Sources

- https://github.com/dimitri/pgloader (README: v3 and v4)
- https://pgloader.readthedocs.io/en/latest/ref/mysql.html
- https://pgloader.readthedocs.io/en/latest/ref/sqlite.html
- https://pgloader.readthedocs.io/en/latest/ref/mssql.html
- https://pgloader.readthedocs.io/en/latest/quickstart.html
- https://apt.postgresql.org (pgloader package)
