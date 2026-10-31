---
title: PostgreSQL log reports and alternative collectors
author: MOZGII, Inc.
lang: en
---

# PostgreSQL log reports and alternative collectors

This reference covers what to do with PostgreSQL server logs after they are written (shipping, pgBadger reports) and
the two main alternatives to postgres_exporter: pgwatch and the OpenTelemetry Collector's `postgresql` receiver.
Versions checked in October 2026: pgBadger 13.2, pgwatch 6.1.0, OpenTelemetry Collector contrib v0.164.1.

## Contents

The sections of this reference on logs and collectors:

1. Shipping PostgreSQL logs off the host
2. pgBadger reports: one-off, incremental and parallel
3. pgwatch as an all-in-one collector
4. The OpenTelemetry Collector postgresql receiver
5. Choosing a metrics collector

## Shipping PostgreSQL logs off the host

Server logs on the database host are lost with the host, fill its disk, and are readable by anyone with shell
access there. Ship them to central storage with retention and access control.

- Write `jsonlog` (`log_destination = 'jsonlog'`, `logging_collector = on`): each line is one JSON object, so a
  shipper needs no multi-line or prefix parsing. `csvlog` is the older structured option.
- Rotation: `log_rotation_age` (default 1 day) and `log_rotation_size` (default 10 MB); `log_truncate_on_rotation`
  with a weekday `log_filename` (`postgresql-%a.json`) keeps a fixed week of files on the host.
- Shippers that tail files: Fluent Bit, Vector, the OpenTelemetry Collector `filelog` receiver, or the cloud
  provider's agent. On managed services, logs go to the provider's log service (CloudWatch, Cloud Logging, Azure
  Monitor), from where they are exported.
- Windows: `log_destination = 'eventlog'` sends messages to the Windows Event Log; register the event source with
  `regsvr32` on `pgevent.dll` as described in the PostgreSQL documentation (Windows section of server setup).
- Linux and macOS: `syslog` hands lines to the system logger (`syslog_facility`, `syslog_ident`); long statements
  are split into several syslog lines (`syslog_split_messages`).

`SELECT pg_current_logfile()` and `SELECT pg_current_logfile('jsonlog')` return the file being written, relative
to the data directory unless `log_directory` is absolute; `pg_ls_logdir()` lists the files (needs `pg_monitor` or
superuser).

## pgBadger reports: one-off, incremental and parallel

pgBadger is a Perl log analyzer that builds HTML (or text, JSON, binary) reports of slow queries, errors, locks,
connections, checkpoints, autovacuum and temp files from the server log. JSON output needs the Perl module
`JSON::XS`; HTML and text need no extra modules. Packages: `pgbadger` in the PGDG apt repository (13.2 checked) and
most Linux distributions; on macOS and Windows run it with any Perl 5.

These commands ran against an 18.6 jsonlog file:

```bash
pgbadger -f jsonlog -o report.html postgresql-2026-10-28.json            # one report
pgbadger -f jsonlog -x text -o - postgresql-2026-10-28.json              # text to stdout
pgbadger -f jsonlog -j 2 -o report.html postgresql-2026-10-28.json       # one big file, two CPUs
pgbadger -f jsonlog -I -O /var/www/pgbadger --retention 4 /var/log/pg/postgresql-*.json
```

- `-I` (incremental) writes per-day folders and `week-NN` summaries under `-O`, and records the last parsed
  position in `LAST_PARSED`, so a nightly cron run only reads new lines. `--retention` keeps that many weeks.
- `-j N` splits one file across N processes; `-J N` parses N files at once.
- For `stderr` logs pass `--prefix` with the exact `log_line_prefix`; for `jsonlog` and `csvlog` no prefix is
  needed.
- What pgBadger can report depends on what was logged: `log_min_duration_statement` (0 logs everything, which is
  expensive on busy servers), `log_lock_waits`, `log_temp_files`, `log_autovacuum_min_duration`,
  `log_checkpoints`, `log_connections` and `log_disconnections`.
- The report contains SQL text, and with parameter logging on, values; store it where the logs themselves may be
  stored.

## pgwatch as an all-in-one collector

pgwatch (Cybertec) is a Go collector built only for PostgreSQL. It runs preset metric queries on a schedule,
stores results in PostgreSQL (or TimescaleDB) or Prometheus, and ships Grafana dashboards and a web UI to add
monitored databases.

```bash
docker run --detach --name pgwatch-demo -p 3000:3000 -p 8080:8080 -e PW_TESTDB=true cybertecpostgresql/pgwatch-demo
```

This command is from the project's README and was not run for this reference. The demo image bundles the collector, a metrics database and Grafana for a trial; production uses the
`cybertecpostgresql/pgwatch` image (or the binaries) with your own metrics store, as the project's README describes.
Choose pgwatch when you want Postgres-specific dashboards, including wait event sampling and statement history,
without building them.

## The OpenTelemetry Collector postgresql receiver

The `postgresql` receiver in the OpenTelemetry Collector contrib distribution reads PostgreSQL statistics views and
emits OpenTelemetry metrics, so Postgres lands in the same backend as application traces. Its README lists metrics
as `beta` and logs as `development`. This section was checked against that README (Collector v0.164.1), not run.

- The monitoring user needs `SELECT` on `pg_stat_database`; for the query events, grant `pg_monitor`.
- The `db.server.top_query` event reads `pg_stat_statements` (the extension must be created in the database the
  receiver connects to, `connect_database`, default `postgres`) and reports deltas of time, calls, rows and block
  counters; `db.server.query_sample` samples running queries from `pg_stat_activity`.
- Both events are opt-in under `events:` in the receiver configuration.
- Metric names and attributes have changed between Collector releases; build alerts from the README of the version
  you deploy.

## Choosing a metrics collector

Pick one collector per estate; two collectors double the load and disagree on numbers.

| Need | Choose |
|---|---|
| Prometheus and Alertmanager already run everything else | postgres_exporter |
| Postgres-only team, wants ready dashboards and wait sampling | pgwatch |
| OpenTelemetry pipeline for traces and metrics across services | Collector `postgresql` receiver |
| Managed service only | the provider's metrics (CloudWatch, Cloud Monitoring, Azure Monitor) plus postgres_exporter for what they miss |
