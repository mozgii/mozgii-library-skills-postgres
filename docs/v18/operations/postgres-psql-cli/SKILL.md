---
name: postgres-psql-cli
description: 'Uses psql and the PostgreSQL 18 command-line tools at a professional level: connecting with service files and .pgpass, meta-commands, variables and interpolation, \gset, \gexec, \if, \watch, \crosstabview, output formats and pagers, a .psqlrc, \copy, extended protocol with \bind and the 18 commands \parse, \bind_named and pipelines, safe scripting with ON_ERROR_STOP and --single-transaction and exit codes, plus the pg_dump, pg_restore, pg_dumpall, pg_basebackup and pg_isready flags that matter, and pgcli and pg_activity. Use when writing a psql script for CI or migrations, automating Postgres from a shell, a script "succeeded" but did nothing, or looking for the right psql or pg_dump flag.'
metadata:
  tags:
  - postgres
  - psql
  - cli
  - scripting
  - pg_dump
  - pg_restore
  - pg_basebackup
  - pg_isready
  - psqlrc
  - pgcli
---

# PostgreSQL psql and command-line tools

psql is both an interactive shell and a script runner, and the two need different settings. Interactive: a
`.psqlrc` with `\x auto`, timing and safe rollback. Scripts and automation: always `psql -X -v ON_ERROR_STOP=1`,
plus `--single-transaction` when the script must apply completely or not at all, connection details from a service
file or environment rather than the command line, and a check of the exit code. Every command below was run with
psql 18.6. Backup strategy lives in `postgres-backup-restore`; this skill is about the tools and their flags.
Dump, restore and base backup flags in depth:
[references/dump-restore-flags.md](references/dump-restore-flags.md).

## Step 0: confirm the client and server versions

Client tools should be at least as new as the server: an older psql misses meta-commands and an older `pg_dump`
refuses newer servers.

```bash
psql --version; pg_dump --version
psql -X -At -c 'SHOW server_version'
```

Inside psql, `\conninfo` (a table in 18: database, user, socket or host, port, protocol version, SSL, superuser,
hot standby) shows where you are before you run anything.

## Connecting without passwords on the command line

A password in a command line is visible to other users in the process list and stays in shell history. Use a
service file for connection settings and a password file (or a secret injected into `PGPASSWORD` by the runner).

```ini
# ~/.pg_service.conf   (Windows: %APPDATA%\postgresql\.pg_service.conf; or PGSERVICEFILE)
[app-prod-ro]
host=db1.internal
port=5432
dbname=app
user=report_ro
sslmode=verify-full
sslrootcert=/etc/ssl/acme-root.crt
application_name=ops-psql
```

The matching password file has one line per server, database and role:

```text
# ~/.pgpass   (Windows: %APPDATA%\postgresql\pgpass.conf; or PGPASSFILE)   chmod 0600 on Unix
db1.internal:5432:app:report_ro:the-password
```

Then `psql service=app-prod-ro` or `PGSERVICE=app-prod-ro psql`. On Linux and macOS a `.pgpass` readable by group
or others is ignored with `WARNING: password file ... has group or world access`; Windows does no permission check.
`-w` (`--no-password`) makes a script fail instead of hanging at a password prompt.

## Meta-commands for looking around

Backslash commands describe objects without writing catalog queries. Add `+` for more detail and, new in 18, `x`
for expanded output of any list command.

| Command | Shows |
|---|---|
| `\d app.orders`, `\d+` | columns, indexes, constraints, triggers; `+` adds storage and size |
| `\dt+x app.*` | tables with size, in expanded form (18) |
| `\di`, `\dv`, `\dm`, `\ds`, `\df+`, `\dT` | indexes, views, materialized views, sequences, functions, types |
| `\dn+`, `\dp`, `\ddp`, `\drg` | schemas, privileges, default privileges, role grants (16+) |
| `\dx`, `\dconfig log_*` | extensions (18 adds the default version), non-default settings by pattern (15+) |
| `\sf app.fn`, `\sv app.v` | function or view source |
| `\errverbose` | the last error with SQLSTATE and source location |

## Variables, interpolation and \gset

psql variables are set with `\set` or `-v name=value` and expand in three forms: `:name` as is, `:'name'` as a
quoted literal, `:"name"` as a quoted identifier. The quoted forms escape properly, so use them for anything that
came from outside.

```sql
\set tbl 'orders'
\set who 'O''Brien'
SELECT count(*) FROM app.:"tbl" WHERE note IS DISTINCT FROM :'who';
SELECT current_database() AS db, pg_size_pretty(pg_database_size(current_database())) AS size \gset
\echo database :db is :size
SELECT count(*) AS n_orders FROM app.orders \gset app_
\echo :app_n_orders
```

`\gset prefix_` stores each column of a one-row result in a variable. Variables do not expand inside quoted SQL
literals or dollar-quoted bodies, so `'... :var ...'` stays literal text.

## Conditionals with \if and generated SQL with \gexec

`\if`, `\elif`, `\else`, `\endif` branch on a variable that is true or false, which together with `\gset` makes
scripts that adapt to the server. `\gexec` runs each value of a result as a statement.

```sql
SELECT current_setting('server_version_num')::int >= 180000 AS is_pg18 \gset
\if :is_pg18
  \echo 'PostgreSQL 18 or later'
\else
  \echo 'older server'
\endif

SELECT format('ANALYZE %I.%I', schemaname, relname)
FROM pg_stat_user_tables WHERE schemaname = 'app' AND last_analyze IS NULL ORDER BY 1 \gexec
```

Build statements with `format()` and `%I`/`%L`, never by concatenating names. `\gexec` runs each statement on its
own, so it can issue commands that refuse a transaction block, such as `CREATE INDEX CONCURRENTLY` (unless the
script runs with `--single-transaction`).

## Watching a query with \watch

`\watch` reruns the last query on an interval. Options: `i=` seconds, `c=` count, `m=` minimum rows (stop when
fewer come back, 17+); 18 adds the variable `WATCH_INTERVAL` for the default interval.

```sql
SELECT count(*) AS active FROM pg_stat_activity WHERE state = 'active' \watch i=0.2 c=2
SELECT pid FROM pg_stat_activity WHERE backend_type = 'autovacuum worker' \watch i=5 m=1
```

The second line watches until no autovacuum worker is running. `PSQL_WATCH_PAGER` (Unix) sends each round to a
pager such as `pspg --stream`.

## Pivot output with \crosstabview

`\crosstabview` turns a three-column result (row, column, value) into a grid without the `tablefunc` extension.

```sql
SELECT status, customer_id % 3 AS bucket, count(*) FROM app.orders WHERE customer_id < 6
GROUP BY 1, 2 ORDER BY 1, 2 \crosstabview status bucket count
```

## Output formats, files and pagers

Output settings live in `\pset`; one query can override them with `\g (...)`.

```sql
SELECT id, status FROM app.orders ORDER BY id LIMIT 2 \g (format=csv tuples_only=off)
SELECT id, status FROM app.orders ORDER BY id LIMIT 1 \gx
SELECT id, status, updated_at FROM app.orders \gdesc
```

From the shell, `--csv`, `-A -t -F $'\t'` (unaligned, tuples only, tab separator) and `-o file` give
machine-readable output. `\x auto` switches to expanded rows when a row is wider than the screen. The pager comes
from `PSQL_PAGER` or `PAGER`; `\pset pager off` or `PAGER=''` disables it in automation.

## Extended protocol: \bind, \parse and pipelines in psql 18

psql normally uses the simple query protocol; these commands send Parse/Bind/Execute instead, which reproduces what
drivers do (prepared statements, `$1` parameters) and tests pooler behaviour.

```sql
SELECT id, status FROM app.orders WHERE id = $1 \bind 42 \g
SELECT id, status FROM app.orders WHERE id = $1 \parse get_order
\bind_named get_order 7 \g
\close_prepared get_order
\startpipeline
SELECT 1 AS a \bind \sendpipeline
SELECT $1::int + 1 AS b \bind 41 \sendpipeline
\syncpipeline
\getresults
\endpipeline
```

`\bind` (16+) binds parameters to the query buffer. 18 adds `\parse` (named prepared statement), `\bind_named`,
`\close_prepared`, and pipelines (`\startpipeline`, `\sendpipeline`, `\syncpipeline`, `\flushrequest`, `\flush`,
`\getresults`, `\endpipeline`; `%P` in the prompt shows pipeline state). `COPY` is not allowed in a pipeline.

## A .psqlrc for daily work

psql reads the system `psqlrc` and then `~/.psqlrc` (Windows: `%APPDATA%\postgresql\psqlrc.conf`; or `PSQLRC`)
unless `-X` is given; `~/.psqlrc-18` is read in preference on version 18. This file was loaded by psql 18.6:

```text
\set QUIET 1
\set ON_ERROR_ROLLBACK interactive
\set COMP_KEYWORD_CASE upper
\set HISTCONTROL ignoredups
\set HISTFILE ~/.psql_history- :DBNAME
\set PROMPT1 '%n@%/%R%x%P%# '
\set WATCH_INTERVAL 5
\pset null '(null)'
\x auto
\timing on
\set active 'SELECT pid, usename, state, wait_event_type, wait_event, now() - query_start AS running, left(query, 60) AS query FROM pg_stat_activity WHERE state <> ''idle'' AND pid <> pg_backend_pid() ORDER BY running DESC NULLS LAST;'
\set QUIET 0
```

`ON_ERROR_ROLLBACK interactive` wraps each interactive statement in a savepoint, so a typo does not abort an open
transaction; it stays off in scripts. `:active` runs the saved query. `%x` shows the transaction state in the
prompt, which prevents leaving an `idle in transaction` session behind.

## Scripts: ON_ERROR_STOP, single transaction and exit codes

By default psql reports an error and carries on with the next statement, then exits 0. That is the most common
cause of a deploy that "succeeded" but applied half a migration. Always run scripts like this:

```bash
psql -X -v ON_ERROR_STOP=1 --single-transaction -d app -f migrate.sql
echo "exit $?"
```

Exit codes measured on psql 18.6:

| Situation | Exit code |
|---|---|
| script with an error, no `ON_ERROR_STOP` | 0 (later statements ran) |
| script with an error, `ON_ERROR_STOP=1` | 3 (stops at the error) |
| `--single-transaction` without `ON_ERROR_STOP` | 0, and nothing is committed |
| `-c` with a failing statement | 1 |
| cannot connect | 2 |
| success | 0 |

- `--single-transaction` (`-1`) wraps all `-c` and `-f` in `BEGIN`/`COMMIT` and sends `ROLLBACK` on error only
  with `ON_ERROR_STOP` set. Statements that refuse transaction blocks (`CREATE INDEX CONCURRENTLY`, `VACUUM`,
  `CREATE DATABASE`) cannot be in such a script.
- `-c` takes either one backslash command or SQL only; meta-commands with SQL (`\bind`) need `-f` or standard
  input.
- In 18.6, inline data after a `COPY ... FROM STDIN` that fails at the start is skipped up to the `\.` line, so
  every inline data block must end with `\.`.

## \copy versus COPY

`COPY ... FROM 'file'` reads a file on the database server as the server's OS user and needs superuser or
`pg_read_server_files`; `\copy` reads or writes on the client and streams through the connection. Use `\copy` for
anything on your machine or a CI runner.

| File lives on | Use | Why the other loses |
|---|---|---|
| Your machine or a CI runner | `\copy` | `COPY` looks on the server, and needs rights you should not grant |
| The database server, moved by a job there | `COPY` | `\copy` sends every byte through the client connection |
| Inside a driver's code | the driver's `COPY ... FROM STDIN` | `\copy` exists only in psql |

```sql
\copy (SELECT id, status FROM app.orders WHERE id <= 3 ORDER BY id) TO 'orders.csv' WITH (FORMAT csv, HEADER)
\copy app.customers FROM 'cust.csv' WITH (FORMAT csv, HEADER true, ON_ERROR ignore, LOG_VERBOSITY verbose)
```

Relative paths are relative to psql's working directory. `ON_ERROR ignore` (17+) skips rows that fail type
conversion and reports how many; it does not skip constraint violations. Bulk loading at scale is a separate topic.

## pg_dump, pg_restore, pg_dumpall, pg_basebackup and pg_isready

These flags change results in ways people miss; all were run against 18.6. Full tables per tool:
[references/dump-restore-flags.md](references/dump-restore-flags.md).

```bash
pg_dump -Fd -j 4 -Z zstd:3 --statistics -f app.dir app      # parallel needs -Fd; stats are not dumped by default in 18
pg_dump -Fc --filter=dump.filter -f app.dump app             # include/exclude rules from a file (17+)
pg_restore -l app.dir > toc.list                              # edit the list, then restore with -L toc.list
pg_restore -d app_copy --section=pre-data --no-owner --no-privileges --exit-on-error app.dir
pg_restore -d app_copy --section=data -j 4 --exit-on-error -L toc.list app.dir
pg_restore -d app_copy --section=post-data -j 4 --exit-on-error app.dir
pg_dumpall --globals-only --no-role-passwords -f globals.sql  # roles and tablespaces; pg_dump never has them
pg_basebackup -D /backups/base -X stream -c fast -P --manifest-checksums=SHA256 && pg_verifybackup /backups/base
pg_isready -h db1.internal -p 5432 -t 3                       # 0 accepting, 1 rejecting, 2 no response, 3 bad args
```

## pgcli and pg_activity

pgcli (4.7.1; Python, `pipx install pgcli` or the distribution package) adds autocompletion and syntax
highlighting; it reads `~/.config/pgcli/config` and accepts libpq connection strings. Keep psql for scripts.
pg_activity (3.6.2; `pipx install "pg_activity[psycopg]"` or `apt install pg-activity`) is a `top` for Postgres:
running queries, waits, blocking, CPU and I/O per backend, with `--min-duration`, `--filter` and `--rds` for
managed services where host metrics are not readable. Run it as a role with `pg_monitor`; cancelling or terminating
from it needs `pg_signal_backend`.

## Verify a psql script before it reaches production

This proves the error handling on your own psql; the exit codes below were measured on 18.6.

```bash
printf 'SELECT 1/0;\nSELECT 2;\n' > check.sql
psql -X -d app -f check.sql; echo "exit $?"                                      # 0: it carried on
psql -X -v ON_ERROR_STOP=1 -d app -f check.sql; echo "exit $?"                   # 3: it stopped
psql -X -v ON_ERROR_STOP=1 --single-transaction -d app -f migrate.sql; echo "exit $?"
pg_isready -h db1.internal -p 5432 -t 3; echo "exit $?"
```

Run a real migration against a scratch copy, then check the result with `\d` or a query. For a dump, list it with
`pg_restore -l` and restore it into a scratch database at least once.

## Gotchas

These are the CLI failures seen most often, each with its cause and fix.

1. **The deploy passed but half the migration is missing.** No `ON_ERROR_STOP`: psql continued and exited 0. Add
   `-v ON_ERROR_STOP=1` and check `$?`.
2. **`-1` reported success and nothing changed.** `--single-transaction` without `ON_ERROR_STOP` ends an aborted
   transaction with `COMMIT`, which rolls back, and exits 0.
3. **A script behaves differently on a colleague's machine.** Their `~/.psqlrc` set `AUTOCOMMIT off` or
   `ON_ERROR_ROLLBACK`. Scripts always run with `-X`.
4. **`invalid command \restrict` when loading a plain-format dump.** pg_dump writes `\restrict` since the August 2025
   minor releases (17.6 on the 17 branch); restore with a psql at least that new.
5. **`\copy` cannot find the file.** The path is relative to where psql runs, not to the server.
6. **pg_dump refuses to dump the server.** pg_dump cannot dump a server of a newer major version than its own.
   Use the newest major's client tools.
7. **`pg_restore -j` is slow or refuses.** Parallel restore needs a custom or directory archive, and parallel dump
   needs `-Fd`.

## Anti-patterns with psql and the client tools

Most of these work by accident on one laptop.

| Do not | Do instead |
|---|---|
| Run scripts without `-X -v ON_ERROR_STOP=1` | Use both, and check `$?` |
| Put `PGPASSWORD=...` or a password URI in a CI command line | Use a service file, a password file or a secret the runner injects |
| Paste a name from outside with `:var` | Use `:'var'` for literals and `:"var"` for identifiers |
| Build `\gexec` statements by concatenation | Build them with `format()` and `%I` or `%L` |
| Use `pg_dump -Fp` for a big database | Use `-Fd -j` or `-Fc`, so restores can be parallel and selective |
| Dump with an older `pg_dump` than the server | Use the client tools of the newest major you touch |

## Checklist

Check these points before you call a psql script done.

- [ ] Every non-interactive call uses `-X -v ON_ERROR_STOP=1`, and the caller checks the exit code.
- [ ] Atomic scripts use `--single-transaction` and contain no `CONCURRENTLY` or `VACUUM`.
- [ ] Connection settings come from a service file or environment; no password in argv or the repository.
- [ ] Values from outside are interpolated with `:'var'` or `:"var"`, never `:var`.
- [ ] Dumps use `-Fd -j` or `-Fc`, include `--statistics` when you want planner stats, and globals are dumped
      separately.
- [ ] Client tools are the same major as the newest server they touch.

## See also

Related skills in this library, each one works on its own:

- `postgres-backup-restore`: backup strategy and drills.
- `postgres-libpq-protocol`: connection strings, service files and `.pgpass`.
- `postgres-schema-migrations`: what goes in a migration script.
- `postgres-bulk-load-etl`: loads at scale.
- `postgres-schema-exploration`: finding your way around an unknown database.

## Sources

- https://www.postgresql.org/docs/18/app-psql.html
- https://www.postgresql.org/docs/18/app-pgdump.html, app-pgrestore.html, app-pg-dumpall.html
- https://www.postgresql.org/docs/18/app-pgbasebackup.html, app-pg-isready.html
- https://www.postgresql.org/docs/18/libpq-pgpass.html, libpq-pgservice.html
- https://www.postgresql.org/docs/18/release-18.html, https://www.postgresql.org/docs/release/18.6/ and 17.6/
- https://github.com/dbcli/pgcli (4.7.1), https://github.com/dalibo/pg_activity (3.6.2)
