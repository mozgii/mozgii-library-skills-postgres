---
name: postgres-monitoring-observability
description: 'Builds monitoring for PostgreSQL 18 in production: which signals to graph and page on, postgres_exporter with Prometheus alert rules and Grafana, the statistics views that changed in 18 (pg_stat_io in bytes with WAL rows, pg_stat_wal, pg_stat_checkpointer, per-backend I/O), wait event sampling, pg_stat_statements as a metric source, a logging baseline (log_line_prefix, jsonlog, log_connections, log_lock_waits, log_lock_failures), pgBadger, pgwatch and OpenTelemetry. Use when setting up dashboards or alerts for Postgres, choosing what to log, wiring Prometheus or Grafana, reading pg_stat_io, or asking why nobody noticed an outage.'
metadata:
  tags:
  - postgres
  - monitoring
  - observability
  - prometheus
  - postgres_exporter
  - grafana
  - logging
  - pgbadger
  - pg_stat_io
  - alerts
---

# PostgreSQL monitoring and observability

Monitoring answers two questions: is the database serving (up, connections, latency, errors) and is it heading for
an outage (disk, WAL, replication, wraparound, vacuum). Metrics answer "how much and since when", logs answer "which
statement and who", so run both: a metrics pipeline (postgres_exporter into Prometheus, or pgwatch) for graphs and
alerts, and structured server logs (jsonlog) shipped off the host for pgBadger and investigations. The one-off
health queries and starting thresholds are in `postgres-operations` (its monitoring-queries reference); slow-query
work with `pg_stat_statements` and `auto_explain` is in `postgres-query-performance`; this skill builds the
always-on system. Tested alert rules: [references/prometheus-alerts.md](references/prometheus-alerts.md). A
snapshot script: [scripts/stats-snapshot.sql](scripts/stats-snapshot.sql); its main queries are in the sections below,
for an install that has no script files.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: check what the server already collects

Most monitoring gaps are settings that were never turned on, so read them first.

```sql
SELECT name, setting, context FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'compute_query_id', 'track_io_timing', 'track_wal_io_timing',
               'track_functions', 'track_cost_delay_timing', 'log_destination', 'logging_collector',
               'log_line_prefix', 'log_min_duration_statement', 'log_connections', 'log_lock_waits',
               'log_autovacuum_min_duration')
ORDER BY name;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_stat_statements', 'pg_buffercache');
```

Fresh 18.6 defaults: `track_io_timing`, `track_wal_io_timing` and `log_lock_waits` off, `log_connections`
empty, `log_min_duration_statement` -1, `log_destination` stderr. Before turning timing on, run `pg_test_timing`:
it prints the timer overhead on that machine.

## What to watch and what to page on

A small set of signals catches nearly every incident; everything else is for diagnosis. Each row names the
postgres_exporter 0.20.1 metric that carries it (verified against a live scrape of 18.6).

| Signal | Why | Exporter metric | Page when |
|---|---|---|---|
| server reachable | outage | `pg_up` | 0 for 1 min |
| connections used | "too many clients" next | `pg_stat_activity_count` / `pg_settings_max_connections` | over 90% |
| oldest open transaction | bloat, blocked DDL | `pg_stat_activity_max_tx_duration` | over 30 min |
| transaction ID age | writes stop at wraparound | `pg_database_wraparound_age_datfrozenxid_seconds` | over 1 billion |
| replication lag | stale reads, failover data loss | `pg_replication_lag_seconds` | over your RPO |
| slot retained WAL, inactive slot | disk fills | `pg_replication_slots_pg_wal_lsn_diff`, `pg_replication_slots_active` | over 50 GB, or inactive 30 min |
| archive failures | broken point-in-time recovery | `pg_stat_archiver_failed_count` | rising for 15 min |
| disk free on data and WAL volumes | outage | node_exporter `node_filesystem_avail_bytes` | under 10% |
| query latency and load | user impact | `pg_stat_statements_seconds_total`, `..._calls_total` | per service objective |
| deadlocks, rollbacks | application bugs | `pg_stat_database_deadlocks`, `..._xact_rollback` | ticket, not page |

Disk space comes from the host, not from Postgres: run node_exporter (Linux, macOS) or windows_exporter (Windows)
next to postgres_exporter, or use the cloud provider's volume metrics.

## postgres_exporter with Prometheus and Grafana

postgres_exporter (Prometheus community, 0.20.1, builds for Linux, macOS, Windows and BSDs) connects as a monitoring
role and serves metrics on port 9187. Give it `pg_monitor`, never a superuser, and a connection limit.

```sql
CREATE ROLE metrics LOGIN PASSWORD 'from-your-secret-store' CONNECTION LIMIT 5 IN ROLE pg_monitor;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- in the database the exporter connects to
```

Several useful collectors are off by default in 0.20.1: `stat_statements`, `stat_checkpointer`,
`database_wraparound`, `long_running_transactions`, `stat_wal_receiver`, `statio_user_indexes`,
`stat_activity_autovacuum`, `buffercache_summary`, `postmaster` and `process_idle`. Enable the ones you alert on:

```bash
docker run -d --name pg-exporter -p 9187:9187 \
  -e DATA_SOURCE_URI="db1.internal:5432/postgres?sslmode=verify-full" \
  -e DATA_SOURCE_USER=metrics -e DATA_SOURCE_PASS_FILE=/run/secrets/metrics_pw \
  quay.io/prometheuscommunity/postgres-exporter:v0.20.1 \
  --collector.stat_statements --collector.stat_checkpointer \
  --collector.database_wraparound --collector.long_running_transactions
```

- One exporter per server is simplest; one exporter for many servers uses the `/probe?target=` endpoint with
  `auth_modules` in `postgres_exporter.yml`, so passwords stay out of Prometheus targets.
- `--no-collector.settings` drops a few hundred `pg_settings_*` series per server if you do not graph settings.
- The `DATA_SOURCE_*` variables work in 0.20.1; the README on the main branch marks them for removal in 0.22 in
  favour of `--datasource.*` flags, so pin the image tag and read its README when upgrading.
- The `stat_statements` collector exports by `queryid` (top 100 by default, `--collector.stat_statements.limit`);
  query text only with `--collector.stat_statements.include_query`.
- Grafana: the community dashboard 9628 "PostgreSQL Database" reads these metrics; treat it as a starting point and
  check every panel's metric name against your exporter version.

## Statistics views that changed in PostgreSQL 18

PostgreSQL 18 moved I/O accounting into `pg_stat_io` and trimmed `pg_stat_wal`, so dashboards built for 16 or 17
need changes. `pg_stat_io` now has byte columns (`read_bytes`, `write_bytes`, `extend_bytes`) and rows with
`object = 'wal'`; `pg_stat_wal` lost `wal_write`, `wal_sync`, `wal_write_time` and `wal_sync_time`;
`track_wal_io_timing` now times WAL I/O in `pg_stat_io`.

```sql
SELECT backend_type, object, context, reads, pg_size_pretty(read_bytes) AS read, read_time,
       writes, pg_size_pretty(write_bytes) AS written, write_time, extends, hits, evictions, fsyncs
FROM pg_stat_io
WHERE coalesce(reads, 0) + coalesce(writes, 0) + coalesce(extends, 0) > 0
ORDER BY coalesce(read_bytes, 0) + coalesce(write_bytes, 0) DESC LIMIT 12;

SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal, wal_buffers_full, stats_reset FROM pg_stat_wal;

SELECT num_timed, num_requested, num_done, round(write_time / 1000) AS write_s,
       round(sync_time / 1000) AS sync_s, buffers_written, slru_written FROM pg_stat_checkpointer;
```

How to read them: `client backend` rows with large `writes` in context `normal` mean backends write dirty pages
themselves (shared_buffers or the background writer cannot keep up); a high `wal_buffers_full` means `wal_buffers`
is too small for bursts; `num_requested` above `num_timed` means `max_wal_size` is too small.

Per-backend statistics are new in 18: `pg_stat_get_backend_io(pid)` and `pg_stat_get_backend_wal(pid)` show one
session's I/O and WAL, which finds the job that writes most of the WAL.

```sql
SELECT a.pid, a.usename, a.application_name, w.wal_bytes, w.wal_fpi
FROM pg_stat_activity a CROSS JOIN LATERAL pg_stat_get_backend_wal(a.pid) w
WHERE a.backend_type = 'client backend' ORDER BY w.wal_bytes DESC NULLS LAST LIMIT 10;
```

`pg_stat_database` also gives `sessions_abandoned`, `sessions_fatal`, `sessions_killed`, `checksum_failures`
(data checksums are on by default for clusters created by 18's `initdb`), and `parallel_workers_launched`.

## Sampling wait events

Wait events say what busy sessions are waiting for (a lock, I/O, the client). Sampling them every few seconds and
counting gives a cheap profile of where time goes. `pg_wait_events` (17+) adds a description of each event.

```sql
SELECT a.wait_event_type, a.wait_event, count(*) AS sessions, max(w.description) AS meaning
FROM pg_stat_activity a
LEFT JOIN pg_wait_events w ON w.type = a.wait_event_type AND w.name = a.wait_event
WHERE a.state <> 'idle' AND a.pid <> pg_backend_pid()
GROUP BY 1, 2 ORDER BY 3 DESC;
```

`wait_event IS NULL` on an active session means it is on CPU. Many `Lock` waits point at
`postgres-transactions-locking`; `IO` waits at storage. Continuous sampling needs a collector (pgwatch has it; the `pg_wait_sampling` extension
does it in-server where it can be installed).

## pg_stat_statements as a metric source

`pg_stat_statements` counters only grow, so monitoring graphs them as rates per `queryid` (the exporter's
`pg_stat_statements_seconds_total` and `pg_stat_statements_calls_total`); reading the view by hand is in
`postgres-query-performance`. One check belongs in monitoring: deallocations mean the table was full and history
was lost.

```sql
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
```

If `dealloc` grows, raise `pg_stat_statements.max` (default 5000, restart) or stop generating unique SQL text
(unparameterized `IN` lists, literal values).

## A logging baseline for production

Logs are the audit trail of incidents. This baseline names slow statements, lock waits, temp files, autovacuum,
checkpoints and connections; every line was applied on 18.6 with `ALTER SYSTEM` and a reload:

```sql
ALTER SYSTEM SET log_destination = 'jsonlog';          -- needs logging_collector = on (restart)
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d app=%a client=%h xid=%x qid=%Q ';
ALTER SYSTEM SET log_min_duration_statement = '500ms';
ALTER SYSTEM SET log_lock_waits = on;                   -- waits longer than deadlock_timeout (1 s)
ALTER SYSTEM SET log_lock_failures = on;                -- PG 18: details of failed NOWAIT locks
ALTER SYSTEM SET log_temp_files = '64MB';
ALTER SYSTEM SET log_autovacuum_min_duration = '5s';
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_connections = 'receipt,authentication,authorization,setup_durations';   -- PG 18 list
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_statement = 'ddl';
ALTER SYSTEM SET log_parameter_max_length = 0;          -- do not copy bind parameters into slow-query lines
SELECT pg_reload_conf();
SELECT pg_current_logfile('jsonlog');
```

- `log_line_prefix` applies to `stderr` and `syslog`; jsonlog has fixed keys (`timestamp`, `user`, `dbname`,
  `error_severity`, `state_code`, `message`, `query_id` and more) and needs no prefix pattern.
- `%Q` (query id) is zero unless `compute_query_id` is on or `pg_stat_statements` is loaded (`auto`).
- `log_connections` in 18 takes a list (`receipt`, `authentication`, `authorization`, `setup_durations`, `all`);
  `on` still works and means the first three. `setup_durations` logs fork and authentication time per connection.
- Slow-statement lines include bound parameter values by default (`log_parameter_max_length = -1`); a secret passed
  as a parameter lands in the log. 0 suppresses them.
- Where the file is: `SELECT pg_current_logfile()` on every OS. On Windows `log_destination` also accepts
  `eventlog`; on Linux and macOS `syslog` hands lines to the system logger.

## Shipping logs and reading them with pgBadger

Logs on the database host are lost with the host and readable by anyone with shell access there, so ship them
(Fluent Bit, Vector, the OpenTelemetry Collector's filelog receiver, or the cloud agent) to central storage. For a
periodic report, pgBadger 13.2 parses stderr, syslog, csvlog and jsonlog:

```bash
pgbadger -f jsonlog -o report.html /var/lib/postgresql/18/main/log/postgresql-*.json
```

pgBadger reports only what was logged: query statistics need `log_min_duration_statement`, lock reports need
`log_lock_waits`. Incremental reports, pgwatch as an all-in-one collector, and the OpenTelemetry Collector's
`postgresql` receiver: [references/logs-and-collectors.md](references/logs-and-collectors.md).

## Worked example: "the API timed out for ten minutes and nobody was paged"

1. Grafana shows `pg_up` stayed 1 and connections were at 40%, so the existing alerts never fired.
2. `rate(pg_stat_statements_seconds_total[5m])` by `queryid` shows one query's time jumped 50 times at 14:05.
3. The jsonlog for 14:05 has `still waiting for AccessExclusiveLock on relation` lines (`log_lock_waits`) from a
   migration, with 300 sessions queued behind it.
4. Cause: a migration ran `ALTER TABLE` without `lock_timeout` (`postgres-schema-migrations`).
5. Add the missing alert: page on `max(pg_stat_activity_max_tx_duration{state="active"}) > 120` for 2 minutes,
   and on the share of sessions in `Lock` waits from `pg_stat_activity_count{wait_event_type="Lock"}`.

## Verify the pipeline end to end

A dashboard proves nothing until a real event moves it. Check the scrape, the rules and one alert on purpose. The
curl line ran against postgres_exporter 0.20.1 and PostgreSQL 18.6; the rule files are the tested ones in the
reference.

```bash
curl -s http://localhost:9187/metrics | grep -E '^pg_up'      # pg_up 1
promtool check rules postgres-alerts.yml && promtool test rules postgres-alerts.test.yml
```

```sql
SELECT count(*) AS sessions, count(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waits,
       max(now() - xact_start) AS oldest_xact
FROM pg_stat_activity WHERE backend_type = 'client backend';
BEGIN; SELECT pg_sleep(1900);                     -- in staging: must fire the long-transaction alert after 30 min
```

Then search your central log store for a slow statement you ran on purpose. Its line must have arrived, with no bound
parameter in it.

## Gotchas

These are the monitoring failures seen most often, each with its cause and fix.

1. **Every counter dropped to zero after a failover or crash.** Cumulative statistics are reset after an unclean
   shutdown, a base backup restore or point-in-time recovery. Use `rate()`/`increase()` (they handle resets) and run
   `ANALYZE` on a promoted replica so autovacuum has numbers again.
2. **Dashboards broke after the upgrade to 18.** `pg_stat_wal` lost `wal_write`, `wal_sync` and their times; read
   WAL I/O from `pg_stat_io` rows with `object = 'wal'`.
3. **`pg_stat_statements must be loaded via shared_preload_libraries`.** It was not in the list, or the list was
   quoted as one string in `ALTER SYSTEM` (`= 'a,b'` stores one library named `a,b`). Write `= a, b` and restart.
4. **The exporter shows no query or checkpoint metrics.** Those collectors are disabled by default in 0.20.1; the
   `stat_statements` collector also needs the extension in the database it connects to.
5. **`pg_database_wraparound_age_datfrozenxid_seconds` looks like seconds.** It is an XID count with a misleading
   suffix; alert on 1,000,000,000, not on a time.
6. **A password appeared in the log.** A slow query's bound parameters were logged. Set
   `log_parameter_max_length = 0`, and never pass secrets as SQL literals.
7. **The monitoring role ate the connection slots.** Limit it with `CONNECTION LIMIT`.

## Anti-patterns in Postgres monitoring

These leave you with graphs and no warning.

| Do not | Do instead |
|---|---|
| Alert only on `pg_up` and CPU | Alert on connections, long transactions, XID age, slots, replication and disk |
| Page on every threshold you can graph | Page on what needs action now; send the rest to a ticket |
| Run the exporter as a superuser | Use a `pg_monitor` role with a `CONNECTION LIMIT` |
| Graph raw counters | Graph `rate()` and `increase()`, which handle resets |
| Keep logs only on the database host | Ship them off the host; they vanish with it |
| Log bound parameters by default | Set `log_parameter_max_length = 0` where a parameter can hold a secret |

## Checklist

Check these points before you call monitoring done.

- [ ] `pg_stat_statements` loaded; `track_io_timing` on after checking `pg_test_timing`.
- [ ] Exporter runs as a `pg_monitor` role with a connection limit, over TLS, with the needed collectors enabled.
- [ ] Alerts exist for down, connections, long transactions, XID age, slots, replication lag, archiving and disk.
- [ ] Alert rules pass `promtool check rules` and a `promtool test rules` case each.
- [ ] Logs are jsonlog (or a parseable prefix), shipped off the host, and do not carry bind parameters.
- [ ] Dashboards read 18's `pg_stat_io` and `pg_stat_checkpointer`, not removed columns.
- [ ] A weekly pgBadger report (or an equivalent log query) is reviewed.

## See also

Related skills in this library, each one works on its own:

- `postgres-operations`: one-off health queries and starting thresholds.
- `postgres-query-performance`: `pg_stat_statements` and `auto_explain` by hand.
- `postgres-troubleshooting`: working an incident the alerts found.
- `postgres-replication-ha`: what replication lag means.
- `postgres-kubernetes`: the operator's metrics endpoint.

## Sources

- https://www.postgresql.org/docs/18/monitoring-stats.html
- https://www.postgresql.org/docs/18/runtime-config-logging.html
- https://www.postgresql.org/docs/18/runtime-config-statistics.html
- https://www.postgresql.org/docs/18/pgstatstatements.html
- https://www.postgresql.org/docs/18/release-18.html
- https://github.com/prometheus-community/postgres_exporter (README, v0.20.1 `--help`)
- https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/ (promtool 3.15.1)
- https://grafana.com/grafana/dashboards/9628
- https://github.com/darold/pgbadger (13.2)
- https://github.com/cybertec-postgresql/pgwatch (6.1.0)
- https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/postgresqlreceiver
