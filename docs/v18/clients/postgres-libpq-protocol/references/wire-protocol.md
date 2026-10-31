---
title: PostgreSQL wire protocol for tool builders
author: MOZGII, Inc.
lang: en
---

# PostgreSQL wire protocol for tool builders

This reference covers the parts of the PostgreSQL frontend/backend protocol a tool notices: simple query
transactions, prepared statements, pipeline mode, the COPY sub-protocol, cancel requests and protocol 3.2. Each
behaviour was run with psql 18.6 or psycopg 3.3.6 against PostgreSQL 18.6.

## Multiple statements in a simple query run as one transaction

A simple Query message with several statements runs them in one implicit transaction unless the string contains
its own `BEGIN`/`COMMIT`. This pair shows the first statement rolled back by the failure of the second:

```bash
psql -X -c "INSERT INTO app.t_simple VALUES (1); SELECT 1/0;"    # ERROR: division by zero
psql -X -Atc "SELECT count(*) FROM app.t_simple"                  # 0
```

`SAVEPOINT` fails inside an implicit block, which needs an explicit `BEGIN` first. A `COMMIT` inside one ends it with a warning, and later
statements start a new implicit block. In simple query mode every value comes back as text.

## Prepared statements: unnamed, named and driver thresholds

The extended protocol always prepares a statement; an unnamed one lasts until the next Parse, a named one until the
session ends or it is closed. Named statements are visible in `pg_prepared_statements`. psql 18 can create and
close them without SQL `PREPARE`:

```sql
SELECT $1::int + $2::int AS sum \bind 2 3 \g
SELECT relname FROM pg_class WHERE relname = $1 \parse find_rel
\bind_named find_rel pg_class \g
SELECT name, statement FROM pg_prepared_statements;     -- find_rel | SELECT relname FROM pg_class WHERE relname = $1
\close_prepared find_rel
```

Drivers decide when to name a statement. psycopg 3 prepares a query after it has run `prepare_threshold` times
(default 5); `prepare_threshold=None` turns this off, which older transaction-mode poolers need
(`postgres-connection-pooling`). With `plan_cache_mode = auto` the server plans the first five executions with custom plans, then
switches to a generic plan when its estimated cost is not much higher; `plan_cache_mode` changes the choice (`postgres-query-performance`).

## Pipeline mode: many queries per round trip

Pipeline mode sends queries without waiting for each result; the server runs them in order and flushes results at a
sync point. Only extended-protocol queries are allowed: no multi-statement strings and no `COPY`. If one query fails,
the rest up to the next sync are skipped (`PGRES_PIPELINE_ABORTED`), and in an implicit transaction the earlier ones
roll back. psycopg wraps it in a context manager; 1000 inserts took 8 ms over a local socket:

```python
with conn.pipeline():
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO pipe VALUES (%s, %s)", [(i, f"v{i}") for i in range(1000)])
```

psql 18 has `\startpipeline`, `\sendpipeline` (after `\bind`), `\syncpipeline`, `\flushrequest`, `\getresults` and
`\endpipeline`:

```sql
\startpipeline
INSERT INTO app.t_simple VALUES ($1) \bind 10 \sendpipeline
INSERT INTO app.t_simple VALUES ($1) \bind 11 \sendpipeline
SELECT count(*) FROM app.t_simple \bind \sendpipeline
\endpipeline
```

## The COPY sub-protocol

`COPY ... FROM STDIN` and `COPY ... TO STDOUT` switch the connection into a streaming mode (CopyIn, CopyOut) in which
data moves in chunks without per-row round trips. psql's `\copy` uses it with a file on the client; SQL `COPY` with a
file name reads or writes the server's file system and needs superuser or `pg_read_server_files` /
`pg_write_server_files`. In psycopg:

```python
with conn.cursor() as cur:
    with cur.copy("COPY pipe (id, v) FROM STDIN") as cp:
        for row in rows:
            cp.write_row(row)
    with cur.copy("COPY (SELECT id, v FROM pipe ORDER BY id) TO STDOUT") as cp:
        for row in cp.rows():          # text values unless cp.set_types([...]) is called
            ...
```

The 18.6 minor release fixed psql so a failed `COPY ... FROM STDIN` in a script no longer runs the inline data as
SQL; test scripts that expect such a failure need a `\.` line after the data.

## Cancel requests

A cancel request travels on a new connection that carries the backend's process id and secret key from
`BackendKeyData`; the server checks the pair and interrupts the running statement, which fails with
`57014 canceling statement due to user request`. libpq 17 added `PQcancelCreate`, `PQcancelBlocking` and
`PQcancelStart`, which encrypt the cancel connection like the original one; psycopg's `cancel_safe()` uses them with
libpq 17 or later. Proven:

```python
threading.Timer(0.5, lambda: conn.cancel_safe(timeout=5)).start()
conn.execute("SELECT pg_sleep(10)")      # psycopg.errors.QueryCanceled: canceling statement due to user request
```

A cancel that arrives after the statement finished does nothing. Through a pooler, the pooler must forward the cancel
to the right server connection; `pg_cancel_backend(pid)` from SQL is the alternative.

## Protocol 3.2 and the longer cancel key

Protocol 3.2 (PostgreSQL 18) changes `BackendKeyData` and `CancelRequest` so the secret key is variable length, from
4 to 256 bytes; the 18 server sends up to 32 bytes. Under 3.0 the key is always 4 bytes. A client asks for 3.2 with
`max_protocol_version=3.2` or `latest`; a server that supports only 3.0 answers with `NegotiateProtocolVersion`, and
libpq continues on 3.0 unless `min_protocol_version` forbids it. psycopg reports the result in
`conn.info.full_protocol_version` (`30002` for 3.2); psql shows it in `\conninfo`.
