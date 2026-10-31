---
name: postgres-libpq-protocol
description: 'What every program that connects to PostgreSQL needs to get right, from libpq and the wire protocol: connection URIs and keyword strings, percent-encoding, multiple hosts with target_session_attrs and load_balance_hosts, the service file pg_service.conf, .pgpass and PGPASSFILE, PG* environment variables a tool must not inherit, sslmode and require_auth, application_name, simple versus extended query, prepared statements, pipeline mode, COPY, cancel requests, protocol 3.2 and max_protocol_version in PostgreSQL 18, LISTEN/NOTIFY, and reading catalogs without being hijacked. Use when building a CLI, agent tool, driver wrapper or service that connects to Postgres, writing a connection string, or for "connects to the wrong database", "no password supplied", "server does not support SSL" or "cannot insert multiple commands into a prepared statement".'
metadata:
  tags:
  - postgres
  - libpq
  - connection-string
  - pgpass
  - pg-service
  - wire-protocol
  - pipeline
  - listen-notify
---

# PostgreSQL libpq connections and the wire protocol

Most PostgreSQL clients (psql, pg_dump, psycopg, node-postgres with `pg-native`, Ruby's `pg`, PHP's `pgsql`) use
libpq, and the drivers that do not (pgx, JDBC, Npgsql, asyncpg, postgres.js) copy most of its rules. A tool that
connects should decide every connection field itself, never let the user's environment pick the server, verify TLS
with `verify-full` over a network, name itself with `application_name`, and speak the extended protocol with
parameters. Driver choice is in `postgres-app-drivers` and `postgres-python`; TLS setup on the server is in
`postgres-security-roles`. Behaviour here was run with psql 18.6 and psycopg 3.3.6 (bundled libpq 18.6) against
PostgreSQL 18.6.


## Step 0: read the libpq version and the environment a client inherits

Keywords such as `require_auth`, `load_balance_hosts` and `max_protocol_version` need a minimum libpq, and each
driver may link its own copy. This prints variable names only, because a value may be a password.

```bash
psql --version; pg_config --version
python -c "import psycopg; print(psycopg.pq.version())"     # the libpq psycopg links: 180006 is 18.6
env | cut -d= -f1 | grep '^PG'                              # what would fill any field you leave empty
```

Inside psql, `\conninfo` shows the server, the socket or host, TLS and the protocol version.

## Connection strings: keyword/value and URI

libpq accepts two forms of connection string, and both carry the same keywords. This pair connects to the same
server; a Unix socket directory goes in `host`, percent-encoded inside the URI's authority:

```text
host=db1.internal port=5432 dbname=app user=app_rw sslmode=verify-full application_name=billing-worker
postgresql://app_rw@db1.example:5432/app?sslmode=verify-full&application_name=billing-worker

host=/tmp/pg port=5432 dbname=app user=app_rw                 # Unix socket directory
postgresql://app_rw@%2Ftmp%2Fpg:5432/app                     # same, socket path percent-encoded
postgresql:///app?host=/tmp/pg&port=5432                     # same, socket as a query parameter
```

- Percent-encode reserved characters in a URI password: `p@ss:w/rd#1` is `p%40ss%3Aw%2Frd%231`. Unencoded, libpq
  misreads the parts (`invalid integer value "w" for connection option "port"`).
- `postgres://` and `postgresql://` are both accepted. In keyword form, quote values with spaces in single quotes:
  `options='-c statement_timeout=5s'`.
- Without `host`, Windows connects to `localhost` over TCP; macOS and Linux use a Unix socket in the directory libpq
  was built with (`/tmp` upstream, `/var/run/postgresql` in the Debian and Ubuntu packages).

## Where libpq takes each value: precedence

libpq fills each connection field from the first source that sets it. Proven on 18.6: a `port` in the string beats
the service file, and the service file beats `PGPORT`.

| Order | Source |
|---|---|
| 1 | the connection string or the parameters passed to the driver |
| 2 | the service named by `service=` or `PGSERVICE`, from `pg_service.conf` |
| 3 | `PG*` environment variables |
| 4 | built-in defaults (user = OS user name, dbname = user, port 5432) |
| password only | `.pgpass` / `PGPASSFILE`, consulted when no password was given |

## Environment variables a tool must not inherit

Every libpq keyword has an environment variable (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`,
`PGOPTIONS`, `PGSSLMODE`, `PGTARGETSESSIONATTRS`, `PGSERVICE`, ...), plus `PGTZ`, `PGDATESTYLE` and `PGGEQO`, which set
session settings. A field the tool leaves empty is filled from them, and `PGOPTIONS` applies even when host, port,
database and user are all explicit. This was run with every field explicit:

```bash
env PGOPTIONS="-c search_path=evil,public -c statement_timeout=50" PGTZ=Asia/Tokyo \
  psql -X "host=/tmp/pg port=5432 dbname=postgres user=postgres" \
  -Atc "select current_setting('search_path'), current_setting('statement_timeout'), current_setting('TimeZone')"
# evil,public|50ms|Asia/Tokyo
```

A tool that must reach one specific database removes every `PG*` variable from its own environment before
connecting and passes every field, including `passfile`. `psql -X` skips `psqlrc`, not the environment. The full
variable list and a Python helper: [references/environment-and-files.md](references/environment-and-files.md).
`PGPASSWORD` is visible to other users through the process list on some systems; prefer a password file.

## The connection service file pg_service.conf

A service file names a set of connection parameters, so scripts say `service=reporting` and the host can change in
one place. libpq reads the per-user file first (`~/.pg_service.conf`, on Windows
`%APPDATA%\postgresql\.pg_service.conf`, or the path in `PGSERVICEFILE`), then the system file `pg_service.conf` in
`pg_config --sysconfdir` (or `PGSYSCONFDIR`). This service was used on 18.6:

```ini
[reporting]
host=/tmp/pg
port=5432
dbname=tooldb
user=tool_user
application_name=reporting-tool
connect_timeout=5
```

Connect with `psql "service=reporting"` or `PGSERVICE=reporting psql`; any keyword written next to `service=`
overrides the file. A service file holds no secret by itself; put the password in `.pgpass`.

## The password file .pgpass and PGPASSFILE

The password file supplies a password when the connection string has none. Each line is
`hostname:port:database:username:password`; each of the first four fields may be `*`; the first matching line wins,
so put specific lines first; escape `:` and `\` with `\`. A socket connection matches the host field against the
socket directory path, or `localhost` for the default directory.

| OS | Default path | Permission rule |
|---|---|---|
| macOS, Linux | `~/.pgpass` | must be `0600` or stricter, or libpq ignores it with a warning |
| Windows | `%APPDATA%\postgresql\pgpass.conf` | not checked; keep it in the user's profile |

These commands write one line and lock the file down on macOS or Linux:

```bash
printf '%s\n' '/tmp/pg:5432:tooldb:tool_user:s3cret-pw' > ~/.pgpass && chmod 0600 ~/.pgpass
# with 0644: WARNING: password file ... has group or world access; permissions should be u=rw (0600) or less
```

A `*:*:*:*:secret` line sends that password to any server the environment points to. Tools should pass their own
`passfile=` and never rely on the user's.

## Multiple hosts, target_session_attrs and load_balance_hosts

A connection string can list several hosts; libpq tries them in order until one accepts the connection and matches
`target_session_attrs`. Proven against a primary and a streaming standby:

```text
host=db-standby,db-primary port=5432 dbname=app user=app target_session_attrs=read-write   # lands on the primary
postgresql://app@db-standby:5432,db-primary:5432/app?target_session_attrs=read-write
```

| `target_session_attrs` | Accepts |
|---|---|
| `any` (default) | the first server that answers |
| `read-write` | not in hot standby and `default_transaction_read_only` off |
| `read-only` | the converse of `read-write` |
| `primary` / `standby` | not in recovery / in recovery |
| `prefer-standby` | a standby if any listed host is one, otherwise any |

- `load_balance_hosts=random` (libpq 16+) shuffles the host order per connection; 20 connections split 14/6 in
  the test. The default `disable` always tries the first host first.
- `connect_timeout` applies to each host separately: two hosts with `connect_timeout=5` can wait 10 seconds.
- An authentication failure on one host stops the attempt; the remaining hosts are not tried.
- Only one `target_session_attrs` (and one user) applies to all hosts.

## sslmode and TLS verification from the client

`sslmode` decides whether TLS is used and what is verified; the default `prefer` silently falls back to plain text
and verifies nothing. Each row was run against a TLS server with a self-signed certificate:

| `sslmode` | Encrypts | Verifies CA | Verifies host name | Result in the test |
|---|---|---|---|---|
| `disable` | no | no | no | plain |
| `allow`, `prefer` | if possible | no | no | plain / TLS |
| `require` | yes | only if a root file exists | no | TLS |
| `verify-ca` | yes | yes | no | needs `sslrootcert`; accepted by IP address |
| `verify-full` | yes | yes | yes | needs `sslrootcert`; refused by IP (`does not match host name`) |

Use `sslmode=verify-full` with `sslrootcert=<ca file>` for every network connection, or `sslrootcert=system` to
trust the operating system's CAs (which forces `verify-full`). `sslnegotiation=direct` (PG 17+) skips one round trip
and requires `sslmode=require` or stronger. `sslmode` is ignored on Unix sockets. Server-side TLS is in
`postgres-security-roles`.

## require_auth, channel_binding and application_name

`require_auth` makes the client refuse a server that authenticates differently, which stops a fake or misconfigured
server from accepting the client without a password; `require_auth=scram-sha-256` against a `trust` server fails
with `server did not complete authentication`. `channel_binding=require` additionally binds SCRAM to the TLS
channel. Set `application_name` to the tool's name: it appears in `pg_stat_activity` and in logs with `%a` in
`log_line_prefix`. psql sets `fallback_application_name=psql`, which `application_name` overrides.

## Simple and extended query protocols

The simple query protocol sends one text string that may hold several statements; they run in one implicit
transaction, so a failure rolls back the earlier ones. The extended protocol (Parse, Bind, Execute, Sync) sends the
statement and its parameters separately, which is what makes parameters injection-proof; it allows one statement
per message. Proven with psycopg:

```python
conn.execute("SELECT %s::int; SELECT 2", [1])
# psycopg.errors.SyntaxError 42601: cannot insert multiple commands into a prepared statement
conn.execute("SELECT 1; SELECT 2")     # no parameters: sent as a simple Query, both statements run
```

psql 18 can use the extended protocol directly: `\bind` (16+), `\parse`, `\bind_named` and `\close_prepared` (18).
Prepared statements, pipeline mode, the COPY sub-protocol and cancel requests are in
[references/wire-protocol.md](references/wire-protocol.md); prepared statements through PgBouncer are in
`postgres-connection-pooling`.

## Protocol 3.2 and max_protocol_version in PostgreSQL 18

PostgreSQL 18 introduced protocol version 3.2, whose only change is a longer cancel key (up to 256 bytes instead of
4). libpq 18 still requests 3.0 unless `max_protocol_version=latest` (or `3.2`) is set; it then downgrades to 3.0 on
older servers. `min_protocol_version=3.2` refuses them. Proven with psql 18's `\conninfo`, which shows the version:

```text
psql "dbname=postgres"                                -> Protocol Version 3.0
psql "dbname=postgres max_protocol_version=latest"    -> Protocol Version 3.2   (server 18)
psql "host=pg17 max_protocol_version=latest"          -> Protocol Version 3.0   (server 17, downgraded)
psql "host=pg17 min_protocol_version=3.2"             -> server only supports protocol version 3.0, but "min_protocol_version" was set to 3.2
```

Accepted values are `3.0`, `3.2` and `latest`; `3.1` was never used. The default stays 3.0 for old servers and
middleware (poolers, proxies) that do not support version negotiation; test yours before raising it.

## LISTEN and NOTIFY from a client

`LISTEN channel` subscribes a session; `NOTIFY channel, 'payload'` or `pg_notify(channel, payload)` sends. Delivery
happens at the sender's commit, identical payloads on one channel within a transaction arrive once, and a payload of
8000 bytes or more fails with `22023 payload string too long`. This psycopg loop receives notifications:

```python
with psycopg.connect(dsn, autocommit=True) as conn:
    conn.execute("LISTEN jobs")
    for n in conn.notifies(timeout=30):       # yields psycopg.Notify(channel, payload, pid)
        handle(n.payload)                     # a key to read, not the data itself
```

Listen on a dedicated connection with autocommit, never through a transaction-mode pooler, and re-run `LISTEN`
after every reconnect: notifications sent while disconnected are lost. Queues built on this are in
`postgres-transactions-locking`.

## Reading catalogs safely from a tool

A tool that reads catalogs runs in someone else's database, where any user with `CREATE` on a schema in the
`search_path` can plant a function that wins over a built-in. On 18.6, `public.lower(varchar)` beat
`pg_catalog.lower` for `lower('ABC'::varchar)`. Defend in three ways:

```sql
SET search_path = pg_catalog, pg_temp;                    -- or schema-qualify every function and operator
SELECT to_regclass('app.orders');                         -- NULL instead of an error when missing
SELECT format('%I.%I', n.nspname, c.relname)              -- stable, quoted name for output
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p');
```

Open read-only sessions with `options='-c default_transaction_read_only=on -c statement_timeout=5s'` so a bug cannot
write. Exploring an unknown schema is in `postgres-schema-exploration`.

## Worked example: "the nightly job must reach the primary, whichever node that is"

A service entry keeps the hosts out of the job's code, and `target_session_attrs` lets libpq find the writable node.
With a replica on port 55492 and the primary on 55490, on 18.6:

```ini
# ~/.pg_service.conf
[app_primary]
host=127.0.0.1,127.0.0.1
port=55492,55490
dbname=postgres
target_session_attrs=read-write
connect_timeout=3
application_name=nightly-job
```

`psql "service=app_primary" -Atc "SELECT inet_server_port(), pg_is_in_recovery(), current_setting('application_name')"`
returned `55490|f|nightly-job`: libpq tried the replica first, rejected it and moved on. A URL naming only the replica
with `target_session_attrs=read-write` fails with `session is read-only`, which is the check to run after a failover
drill. `connect_timeout` applies per host, so a dead first node costs that many seconds, not the whole job.

## Verify a tool's connection

Run the tool with a hostile environment, then read from the server what it really got. The query ran on 18.6.

```bash
env PGOPTIONS='-c default_transaction_read_only=on' PGPORT=1 PGSSLMODE=disable your-tool --check
```

```sql
SELECT a.application_name, s.ssl, s.version, a.client_addr
FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid)
WHERE a.pid = pg_backend_pid();                             -- your tool's name; ssl true off localhost
SHOW default_transaction_read_only;                         -- off, whatever PGOPTIONS said
```

A tool that cannot pass this has not removed `PG*`. Test TLS with a wrong host name as well: `sslmode=verify-full`
must refuse it.

## Gotchas

These are the connection and protocol failures seen most often, each with its cause and fix.

1. **The tool connected to the wrong database.** It left `dbname` or `host` empty and `PGDATABASE`/`PGHOST` filled
   it; scrub `PG*` and pass every field.
2. **`fe_sendauth: no password supplied` though `.pgpass` has the line.** The file is not `0600` (macOS, Linux), the
   host field does not match (a socket matches its directory path), or an earlier wildcard line matched first.
3. **`server does not support SSL, but SSL was required`.** The server has `ssl = off` or a pooler in front
   terminates without TLS.
4. **`root certificate file "~/.postgresql/root.crt" does not exist`.** `verify-ca`/`verify-full` without
   `sslrootcert`; pass the CA file or `sslrootcert=system`.
5. **`cannot insert multiple commands into a prepared statement` (42601).** Several statements in one parameterized
   call; send them separately or in a pipeline.
6. **Notifications stop after a network blip.** The driver reconnected but did not `LISTEN` again.
7. **`invalid integer value ... for connection option "port"`.** A URI password with `:`, `@`, `/` or `#` was not
   percent-encoded.

## Anti-patterns in connection handling

Each of these lets the environment or the network decide where a tool connects.

| Do not | Do instead |
|---|---|
| Leave `host` or `dbname` empty and trust the environment | Set every field in the tool and remove `PG*` first |
| Use `sslmode=require` over a network | Use `verify-full` with `sslrootcert`; `require` does not check who answered |
| Put a password in a URI that reaches logs or `ps` | Use the tool's own `passfile` or a secret store |
| Concatenate values into SQL text | Send them as parameters over the extended protocol |
| Trust a `.pgpass` line with `*` fields | Write exact host, port, database and user |
| Keep `LISTEN` on a pooled connection | Use a dedicated autocommit connection and listen again after reconnecting |

## Checklist

Check these points before you ship a tool that connects to PostgreSQL.

- [ ] Every connection field is set by the tool; `PG*` variables are removed from its environment.
- [ ] Passwords come from the tool's own `passfile` or secret store, never `PGPASSWORD` or a URI in logs.
- [ ] Network connections use `sslmode=verify-full` with `sslrootcert`; `require_auth` is set.
- [ ] `application_name` names the tool; `connect_timeout` and `statement_timeout` are set.
- [ ] Queries use parameters (extended protocol); no SQL is built by string concatenation.
- [ ] Failover lists use `target_session_attrs=read-write` for writers.
- [ ] Catalog reads run with `search_path = pg_catalog, pg_temp` in a read-only session.
- [ ] Listeners use a dedicated autocommit connection and re-`LISTEN` after reconnecting.

## See also

Related skills in this library, each one works on its own:

- `postgres-app-drivers`: which driver for which language.
- `postgres-python`: scrubbing `PG*` in Python.
- `postgres-psql-cli`: service files and `.pgpass` from the shell.
- `postgres-security-roles`: server-side authentication.
- `postgres-encryption-tls`: TLS certificates on the server.
- `postgres-connection-pooling`: prepared statements through PgBouncer.
- `postgres-schema-exploration`: reading an unknown schema.

## Sources

- https://www.postgresql.org/docs/18/libpq-connect.html
- https://www.postgresql.org/docs/18/libpq-envars.html
- https://www.postgresql.org/docs/18/libpq-pgservice.html
- https://www.postgresql.org/docs/18/libpq-pgpass.html
- https://www.postgresql.org/docs/18/libpq-ssl.html
- https://www.postgresql.org/docs/18/protocol-overview.html
- https://www.postgresql.org/docs/18/protocol-flow.html
- https://www.postgresql.org/docs/18/protocol-message-formats.html
- https://www.postgresql.org/docs/18/libpq-pipeline-mode.html
- https://www.postgresql.org/docs/18/libpq-cancel.html
- https://www.postgresql.org/docs/18/sql-notify.html
- https://www.postgresql.org/docs/18/app-psql.html
- https://www.psycopg.org/psycopg3/docs/api/connections.html
