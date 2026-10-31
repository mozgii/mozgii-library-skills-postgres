---
title: PgBouncer configuration
author: MOZGII, Inc.
lang: en
---

# PgBouncer configuration

This reference gives a PgBouncer configuration for transaction pooling in front of one PostgreSQL server (PgBouncer
1.26 at the time of writing; read `pgbouncer --version`), with the settings that matter and how to watch it.

## A transaction-pooling pgbouncer.ini

PgBouncer reads one ini file; `[databases]` maps client database names to servers and `[pgbouncer]` holds settings.

```ini
[databases]
app = host=10.0.0.5 port=5432 dbname=app

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_user = pgbouncer_auth
auth_query = SELECT usename, passwd FROM pgbouncer.get_auth($1)
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 80
max_prepared_statements = 200
server_idle_timeout = 600
server_lifetime = 3600
query_wait_timeout = 30
client_tls_sslmode = require
client_tls_cert_file = /etc/pgbouncer/tls/server.crt
client_tls_key_file = /etc/pgbouncer/tls/server.key
server_tls_sslmode = verify-full
server_tls_ca_file = /etc/pgbouncer/tls/ca.crt
admin_users = pgbouncer_admin
ignore_startup_parameters = extra_float_digits,options
```

| Setting | Meaning |
|---|---|
| `auth_user` | the role that looks up other users through `auth_query` |
| `max_client_conn` | client connections PgBouncer accepts |
| `default_pool_size` | server connections per (database, user) pair |
| `max_db_connections` | hard cap per database across users |
| `max_prepared_statements` | protocol-level prepared statements in transaction mode (1.21+) |
| `query_wait_timeout` | fail clients that wait this long for a server connection |

- `default_pool_size` times the number of (database, user) pairs, capped by `max_db_connections`, must stay under
  the server's `max_connections`.
- `query_wait_timeout` default is 120 s; a shorter value surfaces saturation as errors instead of hanging requests.
- Comments go on their own line, starting with `;` or `#`. PgBouncer reads everything after `=` to the end of the line
  as the value. On 1.26.1, `default_pool_size = 20   ; comment` stops the start with `invalid value "20   ; comment"`,
  and the same comment after `auth_user` starts cleanly, then fails every login with `role "pgbouncer_auth   ; comment"
  does not exist`.
- Run 1.26.1 or later: it fixes CVE-2026-107350, a SCRAM login as another user in 1.17.0 to 1.26.0.

## auth_query with a SECURITY DEFINER function

`auth_query` lets PgBouncer check passwords against the server's roles instead of a copy in a file. Run it through a
function so the lookup role needs no superuser rights.

```sql
CREATE ROLE pgbouncer_auth LOGIN PASSWORD '<from your secret store>';
CREATE SCHEMA pgbouncer AUTHORIZATION postgres;
CREATE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE (usename name, passwd text)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT rolname, rolpassword FROM pg_authid
  WHERE rolname = p_usename AND rolcanlogin AND NOT rolsuper;
$$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer_auth;
```

`pgbouncer_auth` itself needs an entry in `auth_file` (`userlist.txt`, mode 0600). When the server requires SCRAM, that
entry must be the plain-text password. PgBouncer opens this connection for itself, with no client whose SCRAM keys it
could reuse, so a stored SCRAM secret fails with `server login failed: wrong password type` and this log line:
`password is SCRAM secret but client authentication did not provide SCRAM keys` (tested on 1.26.1 with `scram-sha-256`
in `pg_hba.conf`). The file then holds a real password, so keep it readable only by PgBouncer's OS user. A role that needs
no password on the server needs no entry at all.

## Watching PgBouncer with the admin console

PgBouncer's admin console is a virtual database named `pgbouncer`.

```bash
psql -h 127.0.0.1 -p 6432 -U pgbouncer_admin pgbouncer -c 'SHOW POOLS;'
```

| Command | Read |
|---|---|
| `SHOW POOLS` | `cl_waiting` above 0 for long means the pool is too small or connections are held too long |
| `SHOW STATS` | transactions and queries per second, average wait time |
| `SHOW CLIENTS` / `SHOW SERVERS` | who is connected and to which server connection |
| `RELOAD` | re-read the config without dropping connections |
| `PAUSE app` / `RESUME app` | hold new queries during a failover or restart |

## Running PgBouncer next to the application or the database

PgBouncer can run on the database host, as a separate tier, or as a sidecar per application host.

- On the database host: one place to configure, but it shares CPU with Postgres.
- As a separate tier with two or more instances behind a load balancer: survives one failure.
- As a sidecar: each app host multiplexes its own clients; the total server connections is sidecars times pool size.
- PgBouncer is single-threaded; for more than one core of pooling work, run several processes with `so_reuseport = 1`.
