---
title: libpq environment variables, service file and password file
author: MOZGII, Inc.
lang: en
---

# libpq environment variables, service file and password file

This reference lists the `PG*` environment variables libpq reads in PostgreSQL 18, shows how a tool removes them,
and gives the exact rules of `pg_service.conf` and `.pgpass` as tested on 18.6.

## PG environment variables that map to connection keywords

Each of these variables fills the matching connection keyword when the connection string leaves it out. A tool that
must reach one database removes all of them before connecting.

| Variable | Keyword | Variable | Keyword |
|---|---|---|---|
| `PGHOST` | `host` | `PGSSLMODE` | `sslmode` |
| `PGHOSTADDR` | `hostaddr` | `PGSSLNEGOTIATION` | `sslnegotiation` |
| `PGPORT` | `port` | `PGSSLCERT`, `PGSSLKEY` | `sslcert`, `sslkey` |
| `PGDATABASE` | `dbname` | `PGSSLCERTMODE` | `sslcertmode` |
| `PGUSER` | `user` | `PGSSLROOTCERT` | `sslrootcert` |
| `PGPASSWORD` | `password` | `PGSSLCRL`, `PGSSLCRLDIR` | `sslcrl`, `sslcrldir` |
| `PGPASSFILE` | `passfile` | `PGSSLSNI` | `sslsni` |
| `PGREQUIREAUTH` | `require_auth` | `PGSSLMINPROTOCOLVERSION`, `PGSSLMAXPROTOCOLVERSION` | `ssl_min_protocol_version`, `ssl_max_protocol_version` |
| `PGCHANNELBINDING` | `channel_binding` | `PGREQUIREPEER` | `requirepeer` |
| `PGSERVICE` | `service` | `PGGSSENCMODE`, `PGKRBSRVNAME`, `PGGSSLIB`, `PGGSSDELEGATION` | GSSAPI keywords |
| `PGOPTIONS` | `options` | `PGCONNECT_TIMEOUT` | `connect_timeout` |
| `PGAPPNAME` | `application_name` | `PGCLIENTENCODING` | `client_encoding` |
| `PGTARGETSESSIONATTRS` | `target_session_attrs` | `PGLOADBALANCEHOSTS` | `load_balance_hosts` |
| `PGMINPROTOCOLVERSION` | `min_protocol_version` | `PGMAXPROTOCOLVERSION` | `max_protocol_version` |
| `PGSSLCOMPRESSION` | `sslcompression` | `PGREQUIRESSL` | `requiressl` (deprecated) |

## PG environment variables that set session behaviour or files

These variables do not map to a keyword but still change what a session does or which file libpq reads.

| Variable | Effect |
|---|---|
| `PGDATESTYLE` | `SET datestyle` at connection start |
| `PGTZ` | `SET timezone` at connection start |
| `PGGEQO` | `SET geqo` at connection start |
| `PGSERVICEFILE` | path of the per-user service file |
| `PGSYSCONFDIR` | directory of the system `pg_service.conf` |
| `PGLOCALEDIR` | directory of message translations |

## Removing PG variables in a Python tool

A Python tool removes the variables from its own process and then names every field, including its own password
file. This script ran with `PGOPTIONS`, `PGHOST` and `PGSSLMODE` set in the calling shell and still reached the
intended database with the default `search_path`:

```python
import os
import psycopg
from psycopg.conninfo import make_conninfo

def safe_conninfo(host: str, port: int, dbname: str, user: str, passfile: str) -> str:
    for key in [k for k in os.environ if k.startswith("PG")]:
        del os.environ[key]          # libpq reads the environment at connect time
    return make_conninfo(host=host, port=port, dbname=dbname, user=user, passfile=passfile,
                         application_name="reporting-tool", connect_timeout=5,
                         max_protocol_version="latest")

with psycopg.connect(safe_conninfo("/tmp/pg", 5432, "tooldb", "tool_user", "/etc/reporting/pgpass")) as conn:
    print(conn.execute("SELECT current_setting('search_path')").fetchone())   # ('"$user", public',)
    print(conn.info.host, conn.info.port, conn.info.full_protocol_version)   # /tmp/pg 5432 30002
```

For a child process (`pg_dump`, `psql`), build its environment from an empty dictionary rather than a copy of
`os.environ`, and pass the connection as one string argument.

## Service file rules

The service file is an INI file whose section names are service names and whose lines are connection keywords.

- Per-user file: `~/.pg_service.conf`, on Windows `%APPDATA%\postgresql\.pg_service.conf`, or `PGSERVICEFILE`.
- System file: `pg_service.conf` in `pg_config --sysconfdir` (Postgres.app 18:
  `/Applications/Postgres.app/Contents/Versions/18/etc/postgresql`), or in `PGSYSCONFDIR`.
- The same service in both files: the per-user one wins.
- A service setting overrides the environment; a keyword in the connection string overrides the service.
- An example ships as `share/pg_service.conf.sample` in the installation.

## Password file rules

The password file is read only when the connection has no password.

- Line format `hostname:port:database:username:password`; `*` matches anything in the first four fields; the first
  matching line is used; `\:` and `\\` escape.
- The host field is compared with `host`, else `hostaddr`, else `localhost`. A Unix socket in the default directory
  also matches `localhost`; in another directory it matches the directory path.
- A database field of `replication` applies to streaming replication logins on a standby.
- macOS and Linux: ignored unless the mode denies group and world (`chmod 0600`). Windows: not checked.
- Location: `~/.pgpass`, `%APPDATA%\postgresql\pgpass.conf` on Windows, or `passfile=` / `PGPASSFILE`.
