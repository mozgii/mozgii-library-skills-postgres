---
name: postgres-testing-ci
description: 'Tests database code against a real PostgreSQL in development and CI: pgTAP tests with plan, has_table, results_eq and throws_ok run by pg_prove, a transaction rolled back per test, template databases cloned in milliseconds with STRATEGY FILE_COPY and file_copy_method clone in 18, Testcontainers in Python, Node, Go, Java and .NET, throwaway clusters with initdb in a temp folder, GitHub Actions service containers with health checks, migrations tested down and up, schema diffs with pg_dump, deterministic seed data, and load tests with custom pgbench scripts. Use when writing tests for SQL, functions or migrations, setting up Postgres in CI, "tests are slow because each one migrates", or benchmarking a query mix.'
metadata:
  tags:
  - postgres
  - testing
  - pgtap
  - ci
  - testcontainers
  - pgbench
  - template-database
  - migrations
---

# PostgreSQL testing and CI

Test database code against the same PostgreSQL major as production, never against SQLite or mocks: constraints,
locking, `ON CONFLICT` and planner behaviour differ. Build the schema once with the real migrations, give each test
an isolated state (a rolled-back transaction, or a database cloned from a template), and run the whole suite in CI
on every change. The pytest wiring is in `postgres-python` (references/testing.md); this skill covers the database
side for any language. Every example ran on PostgreSQL 18.6 (Postgres.app, and the `postgres:18` image for pgTAP and
Testcontainers).

## Step 0: read the versions the tests will run on

Tests prove little unless they run on production's major version, and the schema-diff steps need pg_dump 18, so
compare what the runner has with what production runs. `pg_prove` and Docker are needed only for the sections that
use them.

```bash
psql --version; pg_dump --version; pg_prove --version; docker --version
grep -rn 'postgres:' .github/workflows 2>/dev/null        # the image tag CI uses
```

```sql
SHOW server_version;                                       -- run it on production and on the test server
SELECT default_version, installed_version FROM pg_available_extensions WHERE name = 'pgtap';
```

## Choosing an isolation strategy for tests

Each strategy trades speed against how much of the real behaviour a test can use.

| Strategy | Per-test cost | Allows `COMMIT` in code under test | Parallel workers |
|---|---|---|---|
| one transaction per test, `ROLLBACK` at the end | microseconds | no | one connection each |
| database cloned from a migrated template | 40 ms to 1.5 s for 157 MB (measured below) | yes | one database each |
| fresh cluster per run (`initdb` in a temp folder) | about 1 s once per run | yes | one cluster or many databases |
| container per run (Testcontainers, CI service) | seconds once per run | yes | as above |

Use rollback for unit tests of SQL and functions, a template clone for tests of code that commits, and a container
or throwaway cluster to hold either.

## pgTAP unit tests run by pg_prove

pgTAP is an extension of assertion functions that print TAP; `pg_prove` runs test files and fails the build when an
assertion fails. Each file plans its count, runs inside a transaction and rolls back. This file passed 7 of 7 with
pgTAP 1.3.4 on 18.6:

```sql
-- t/01-customers.sql
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(7);

SELECT has_table('app', 'customers', 'customers table exists');
SELECT col_not_null('app', 'customers', 'email', 'email is required');
SELECT col_is_unique('app', 'customers', 'email', 'email is unique');
SELECT has_function('app', 'spend', ARRAY['bigint', 'bigint']);

INSERT INTO app.customers (email, credit_cents) VALUES ('a@acme.example', 500);
SELECT results_eq(
  $$ SELECT app.spend(id, 200) FROM app.customers WHERE email = 'a@acme.example' $$,
  $$ VALUES (300::bigint) $$,
  'spend() returns the remaining credit');
SELECT throws_ok(
  $$ SELECT app.spend(id, 1000) FROM app.customers WHERE email = 'a@acme.example' $$,
  '23514', NULL, 'overspending violates the check constraint');
SELECT is((SELECT count(*) FROM app.customers)::int, 1, 'one customer');

SELECT * FROM finish();
ROLLBACK;
```

Run the files with `pg_prove`; it exits 1 when any test fails and prints `have:` and `want:` for a failed
`results_eq`:

```bash
pg_prove -h localhost -U postgres -d app_test --ext .sql -r t/    # or: pg_prove -d app_test t/*.sql
```

- `pg_prove` looks for `*.pg` files in a directory unless `--ext` says otherwise; with no match it prints
  `Result: NOTESTS` and exits 0, so a typo silently passes.
- Install: `postgresql-18-pgtap` and `libtap-parser-sourcehandler-pgtap-perl` (apt.postgresql.org), `pgtap_18`
  (yum.postgresql.org), or `make install` from source. Postgres.app and the `postgres:18` image do not include it.
- `throws_ok(sql, '23514', ...)` checks a SQLSTATE; `lives_ok`, `is`, `isnt`, `bag_eq`, `set_eq`, `has_index`,
  `fk_ok`, `policies_are` and `function_returns` cover most schema and data checks.

## Template databases for a fresh database per test

`CREATE DATABASE ... TEMPLATE` copies a migrated database instead of running migrations again. The template must
have no other connections (`source database "x" is being accessed by other users`); mark it so nobody connects by
accident. These timings for a 157 MB template (pgbench scale 10) are from two runs on APFS:

```sql
ALTER DATABASE app_template WITH IS_TEMPLATE true ALLOW_CONNECTIONS false;

CREATE DATABASE t_wal   TEMPLATE app_template;                       -- WAL_LOG default: 0.9 to 1.5 s
CREATE DATABASE t_copy  TEMPLATE app_template STRATEGY = FILE_COPY;  -- 0.2 to 0.4 s
SET file_copy_method = clone;                                        -- PostgreSQL 18
CREATE DATABASE t_clone TEMPLATE app_template STRATEGY = FILE_COPY;  -- 40 to 150 ms
DROP DATABASE t_clone WITH (FORCE);
```

- `WAL_LOG` writes every block to WAL; `FILE_COPY` copies files and forces a checkpoint before and after, which is
  fine on a test server and costly on a busy one.
- `file_copy_method = clone` uses `copyfile` on macOS and `copy_file_range` on Linux, so copy-on-write file systems
  (APFS, Btrfs, XFS with reflinks) share blocks; elsewhere it behaves like a copy. It is a user-level setting.
- Give each parallel worker its own clone (`test_w1`, `test_w2`); `DROP DATABASE ... WITH (FORCE)` ends leftover
  sessions.

## Throwaway clusters with initdb

A test run can create its own cluster in a temporary folder, listening only on a private Unix socket, with
durability settings off because the data is discarded. [scripts/ephemeral-cluster.sh](scripts/ephemeral-cluster.sh)
does this and runs one command with `DATABASE_URL` set; it took about one second end to end with Postgres.app 18.6:

```bash
PG_BIN=/usr/lib/postgresql/18/bin scripts/ephemeral-cluster.sh pytest -q
# inside: initdb --locale-provider=builtin, then postgres -c listen_addresses='' -c fsync=off
#         -c synchronous_commit=off -c full_page_writes=off
```

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

The socket directory is a short path under `/tmp`, because socket paths are limited to about 100 bytes. On Windows
use WSL or a container. A per-app private cluster that must keep its data is in `postgres-local-cluster`.

## Testcontainers in each language

Testcontainers starts a disposable `postgres:18` container from test code and removes it afterwards. Versions checked
on the package registries in October 2026:

| Language | Package | Version |
|---|---|---|
| Python | `testcontainers[postgres]` (import `testcontainers.community.postgres`) | 4.15.0 |
| Node.js | `@testcontainers/postgresql` | 12.2.1 |
| Go | `github.com/testcontainers/testcontainers-go/modules/postgres` | v0.44.0 |
| Java | `org.testcontainers:testcontainers-postgresql` (2.x name; 1.x was `postgresql`) | 2.0.5 |
| .NET | `Testcontainers.PostgreSql` | 4.16.0 |

This Python file ran against Docker 29 and printed `18.6 (Debian 18.6-1.pgdg13+2)`:

```python
import psycopg
from testcontainers.community.postgres import PostgresContainer

with PostgresContainer("postgres:18", driver=None) as pg:     # driver=None: a plain postgresql:// URL
    with psycopg.connect(pg.get_connection_url()) as conn:
        print(conn.execute("SHOW server_version").fetchone()[0])
```

In 4.15.0 the old import `testcontainers.postgres` still works but warns `DeprecationWarning`. Pin the image tag
(`postgres:18`, or a digest), never `latest`.

## PostgreSQL in GitHub Actions with a service container

GitHub Actions runs service containers next to a job on Linux runners only. The health check makes the job wait
until the server accepts connections. This workflow follows GitHub's documented PostgreSQL example, with the job on
the runner and the port mapped to `localhost`:

```yaml
jobs:
  db-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    env:
      DATABASE_URL: postgresql://postgres:postgres@localhost:5432/postgres
    steps:
      - uses: actions/checkout@v6
      - run: ./scripts/check-migrations.sh migrations "$DATABASE_URL"
      - run: ./run-tests.sh
```

For pgTAP, build an image `FROM postgres:18` that installs `postgresql-18-pgtap` and
`libtap-parser-sourcehandler-pgtap-perl` (tested here: healthy in seconds, `pg_prove` passed), push it to your
registry, and use it as the service image. Check `pg_dump --version` on the runner: the migration check needs
`--restrict-key`, which exists in pg_dump 18 and from the August 2025 minors (17.6, 16.10, 15.14, 14.19, 13.22); on an
older client install the PGDG one or run the tools inside the container.

## Testing migrations down and up

A migration test proves each step applies on an empty database, and, if the project writes down migrations, that
each down followed by its up gives back the identical schema.
[scripts/check-migrations.sh](scripts/check-migrations.sh) applies `NNN_up.sql` files in order, then walks back
comparing `pg_dump --schema-only` before and after each down and up; it reported
`OK: 2 migrations go down and up cleanly` on 18.6 and failed for a down that left a table behind. Its dump helper:

```bash
dump() { pg_dump --schema-only --no-owner --no-privileges --restrict-key=schemadiff -d "$db"; }
```

pg_dump 18.6 writes a random `\restrict` key into every plain-text dump, so two dumps of the same schema differ;
`--restrict-key` with a fixed value makes them comparable. Rules for writing migrations are in
`postgres-schema-migrations`.

## Schema diff checks

A schema diff compares a database built by migrations with the schema the code expects, and catches drift (a
hand-made index in production, a migration that was edited after it ran). Two approaches:

- Dump and diff: `pg_dump --schema-only --no-owner --no-privileges --restrict-key=x` of both databases, then `diff`.
  No extra tool; output is SQL text, so reordered objects can show as noise.
- A diff tool that plans the DDL: stripe's `pg-schema-diff` (v1.0.9, `pg-schema-diff plan --from-dsn ... --to-dir
  ./schema`) or Atlas (`atlas schema diff`). `migra` is deprecated; its last release was September 2022, and its
  author points to the successor `results`.

## Deterministic seed data

Seed data for tests should be the same on every run, so a failure can be reproduced. `setseed()` fixes the session's
random sequence; with it, this insert produced the same fingerprint `93c6d03a...` twice on 18.6:

```sql
SELECT setseed(0.42);
INSERT INTO app.seed_customers
SELECT g, format('user%s@test.example', g),
       (ARRAY['US','DE','FR','JP','BR'])[random(1, 5)],    -- random(min, max): PostgreSQL 17+
       random(0, 100000)
FROM generate_series(1, 10000) AS g;
ANALYZE app.seed_customers;
```

Run `ANALYZE` after seeding, or plans in the test differ from production-like plans. A different PostgreSQL major
may produce a different sequence for the same seed.

## Load tests with custom pgbench scripts

pgbench runs SQL scripts from many clients and reports throughput and latency. Custom scripts use `\set` with
`random()`; `@weight` mixes scripts; `--max-tries` retries serialization failures and deadlocks. This mix of 90%
reads and 10% serializable transfers ran at about 97,000 transactions per second on a laptop (8 clients, 5 s):

```text
-- read_account.sql
\set aid random(1, 100000 * :scale)
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;

-- transfer.sql
\set from random(1, 100000 * :scale)
\set to random(1, 100000 * :scale)
\set amount random(1, 500)
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE pgbench_accounts SET abalance = abalance - :amount WHERE aid = :from;
UPDATE pgbench_accounts SET abalance = abalance + :amount WHERE aid = :to;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (1, 1, :from, :amount, now());
COMMIT;
```

```bash
pgbench -i -s 10 bench                                   # once: about 157 MB of test tables
pgbench -n -s 10 -M prepared -c 8 -j 4 -T 60 -P 5 --random-seed=42 \
  --max-tries=10 --failures-detailed -f read_account.sql@9 -f transfer.sql@1 bench
```

With only `-f` scripts pgbench cannot see the scale and uses 1 unless `-s` is given, so `:scale` silently covers a
tenth of a scale-10 table. `-n` skips the vacuum of the built-in tables; `-M prepared` uses named prepared statements.
Reading plans and `pg_stat_statements` during the run is in `postgres-query-performance`.

## Gotchas

These are the testing failures seen most often, each with its cause and fix.

1. **`pg_prove` says `Result: NOTESTS` and CI is green.** It looked for `*.pg` files; pass `--ext .sql` or the
   files themselves.
2. **`source database "app_template" is being accessed by other users`.** A session is connected to the template;
   set `ALLOW_CONNECTIONS false` on it and close tools pointed at it.
3. **Schema diff reports changes in identical databases.** Plain-text dumps from pg_dump 18.6 carry a random
   `\restrict` key; pass `--restrict-key`.
4. **pgbench touches only part of the table.** Custom-script runs default `:scale` to 1; pass `-s`.
5. **Tests pass locally and fail in CI with `connection refused`.** The job started before the server was ready;
   add the `--health-cmd pg_isready` options.
6. **Flaky results after seeding.** No `ANALYZE` after the load, or random data without `setseed()`.

## Anti-patterns in database testing

Each of these gives a green build that proves less than it seems to.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| SQLite or a mock instead of Postgres | constraints, locking and `ON CONFLICT` behave differently | the production major in a container or throwaway cluster |
| The `latest` image tag | a new major arrives without a decision | a pinned tag or digest |
| Running every migration for every test | the suite slows with each migration | one migrated template, cloned per test |
| Parallel workers sharing one database | tests that commit disturb each other | one database per worker |
| `sleep` to wait for the server | flaky on a slow runner, wasteful on a fast one | a `pg_isready` health check |
| `fsync = off` on anything that keeps data | a crash can corrupt the cluster | only on clusters thrown away after the run |
| Load tests on a tiny or empty table | plans and contention differ from production | a realistic scale, `-s` set, and `ANALYZE` first |

## Verify the test setup catches a bad migration

A suite that cannot fail proves nothing, so run the migration check green and then break it on purpose. Both runs
used PostgreSQL 18.6 and the two scripts in this skill.

```bash
PG_BIN=/usr/lib/postgresql/18/bin scripts/ephemeral-cluster.sh \
  bash -c 'scripts/check-migrations.sh migrations "$DATABASE_URL"'     # OK: 1 migrations go down and up cleanly
```

Now change `001_down.sql` to `SELECT 1;` and run it again: it must exit non-zero, here 3, because the second `CREATE
TABLE` fails with `ON_ERROR_STOP`. Then run the whole suite twice in a row, in random order if your runner has it. A
test that passes alone and fails beside another shares state, so fix its isolation.

## Checklist

Check these points before you call a database test suite done.

- [ ] Tests run against the production major version, from a pinned image or binaries.
- [ ] The schema is built by the real migrations, and down/up is checked if downs exist.
- [ ] Each test is isolated by rollback or by its own cloned database.
- [ ] pgTAP files plan their count, roll back, and run with the right `--ext`.
- [ ] CI waits on a health check and fails on any test failure.
- [ ] A schema diff guards against drift between migrations and the expected schema.
- [ ] Seed data is deterministic and analyzed; load tests set `-s` and `--max-tries`.

## See also

Related skills in this library:

- `postgres-python`: pytest wiring
- `postgres-schema-migrations`: rules the migration tests enforce
- `postgres-docker`: the `postgres:18` image
- `postgres-query-performance`: reading plans during a load test

## Sources

- https://pgtap.org/documentation.html and https://pgtap.org/pg_prove.html
- https://www.postgresql.org/docs/18/sql-createdatabase.html
- https://www.postgresql.org/docs/18/manage-ag-templatedbs.html
- https://www.postgresql.org/docs/18/runtime-config-resource.html (file_copy_method)
- https://www.postgresql.org/docs/18/pgbench.html
- https://www.postgresql.org/docs/18/app-pgdump.html
- https://www.postgresql.org/docs/18/app-initdb.html
- https://www.postgresql.org/docs/18/functions-math.html and https://www.postgresql.org/docs/18/release-17.html
- https://docs.github.com/en/actions/tutorials/use-containerized-services/create-postgresql-service-containers
- https://testcontainers-python.readthedocs.io/ and the PyPI, npm, Go proxy, Maven Central and NuGet registries
- https://github.com/stripe/pg-schema-diff and https://github.com/djrobstep/migra (README)
