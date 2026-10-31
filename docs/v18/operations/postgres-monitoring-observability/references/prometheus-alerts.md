---
title: Prometheus alert rules for PostgreSQL with postgres_exporter
author: MOZGII, Inc.
lang: en
---

# Prometheus alert rules for PostgreSQL with postgres_exporter

This reference holds a starting set of Prometheus alert rules for PostgreSQL, written against the metric names of
postgres_exporter 0.20.1 as scraped from a PostgreSQL 18.6 server. The rules pass `promtool check rules`, and three
of them pass the `promtool test rules` cases below (promtool 3.15.1). Tune thresholds to your service objectives.

## Contents

The sections of this reference on alert rules:

1. Exporter flags the rules depend on
2. The alert rules file
3. Unit tests for the rules with promtool
4. Notes on thresholds and labels

## Exporter flags the rules depend on

Some rules read collectors that postgres_exporter 0.20.1 disables by default. Start the exporter with:

```bash
postgres_exporter --collector.stat_checkpointer --collector.database_wraparound \
  --collector.long_running_transactions --collector.stat_statements
```

`pg_replication_slots_*`, `pg_stat_activity_*`, `pg_stat_archiver_*`, `pg_stat_database_*` and
`pg_replication_*` come from collectors that are on by default.

## The alert rules file

Save this as `postgres-alerts.yml` and list it under `rule_files` in `prometheus.yml`.

```yaml
groups:
  - name: postgres
    rules:
      - alert: PostgresDown
        expr: pg_up == 0
        for: 1m
        labels: {severity: page}
        annotations:
          summary: "Exporter cannot reach PostgreSQL on {{ $labels.instance }}"
      - alert: PostgresConnectionsHigh
        expr: sum by (instance) (pg_stat_activity_count) / on (instance) pg_settings_max_connections > 0.8
        for: 5m
        labels: {severity: warn}
        annotations:
          summary: "{{ $labels.instance }} uses more than 80% of max_connections"
      - alert: PostgresLongTransaction
        expr: max by (instance) (pg_stat_activity_max_tx_duration{state=~"active|idle in transaction"}) > 1800
        for: 2m
        labels: {severity: page}
        annotations:
          summary: "A transaction on {{ $labels.instance }} has been open for more than 30 minutes"
      - alert: PostgresXidAgeHigh
        expr: max by (instance, datname) (pg_database_wraparound_age_datfrozenxid_seconds) > 1000000000
        for: 10m
        labels: {severity: page}
        annotations:
          summary: "{{ $labels.datname }} on {{ $labels.instance }} is past 1 billion transactions since freeze"
      - alert: PostgresReplicationSlotInactive
        expr: pg_replication_slots_active == 0
        for: 30m
        labels: {severity: warn}
        annotations:
          summary: "Slot {{ $labels.slot_name }} on {{ $labels.instance }} has had no consumer for 30 minutes"
      - alert: PostgresSlotRetainsWal
        expr: pg_replication_slots_pg_wal_lsn_diff > 50 * 1024 * 1024 * 1024
        for: 10m
        labels: {severity: page}
        annotations:
          summary: "Slot {{ $labels.slot_name }} holds more than 50 GB of WAL"
      - alert: PostgresReplicaLag
        expr: pg_replication_lag_seconds > 300 and pg_replication_is_replica == 1
        for: 5m
        labels: {severity: warn}
        annotations:
          summary: "Replica {{ $labels.instance }} replays WAL more than 5 minutes behind"
      - alert: PostgresArchiveFailing
        expr: increase(pg_stat_archiver_failed_count[15m]) > 0
        for: 15m
        labels: {severity: page}
        annotations:
          summary: "WAL archiving fails on {{ $labels.instance }}"
      - alert: PostgresDeadlocks
        expr: increase(pg_stat_database_deadlocks[10m]) > 5
        labels: {severity: warn}
        annotations:
          summary: "More than 5 deadlocks in 10 minutes in {{ $labels.datname }}"
      - alert: PostgresCheckpointsRequested
        expr: rate(pg_stat_checkpointer_num_requested_total[1h]) > rate(pg_stat_checkpointer_num_timed_total[1h])
        for: 2h
        labels: {severity: ticket}
        annotations:
          summary: "Most checkpoints on {{ $labels.instance }} are forced by WAL volume; raise max_wal_size"
```

Check the file before loading it:

```bash
promtool check rules postgres-alerts.yml
```

## Unit tests for the rules with promtool

A rules unit test feeds synthetic series and states which alerts must fire at which time, so a renamed metric or a
wrong threshold fails in CI instead of in an outage. Save as `postgres-alerts.test.yml` next to the rules:

```yaml
rule_files: [postgres-alerts.yml]
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'pg_stat_activity_count{instance="db1",state="active"}'
        values: '50x10'
      - series: 'pg_stat_activity_count{instance="db1",state="idle"}'
        values: '40x10'
      - series: 'pg_settings_max_connections{instance="db1"}'
        values: '100x10'
      - series: 'pg_replication_slots_active{instance="db1",slot_name="replica_old",database=""}'
        values: '0x40'
      - series: 'pg_stat_activity_max_tx_duration{instance="db1",state="idle in transaction"}'
        values: '2000x5'
    alert_rule_test:
      - eval_time: 6m
        alertname: PostgresConnectionsHigh
        exp_alerts:
          - exp_labels: {severity: warn, instance: db1}
            exp_annotations: {summary: "db1 uses more than 80% of max_connections"}
      - eval_time: 31m
        alertname: PostgresReplicationSlotInactive
        exp_alerts:
          - exp_labels: {severity: warn, instance: db1, slot_name: replica_old}
            exp_annotations: {summary: "Slot replica_old on db1 has had no consumer for 30 minutes"}
      - eval_time: 3m
        alertname: PostgresLongTransaction
        exp_alerts:
          - exp_labels: {severity: page, instance: db1}
            exp_annotations: {summary: "A transaction on db1 has been open for more than 30 minutes"}
```

Run it:

```bash
promtool test rules postgres-alerts.test.yml
```

## Notes on thresholds and labels

These points come from running the exporter against 18.6 and the rules through promtool.

- Labels with an empty value (the physical slot's `database=""`) are dropped by Prometheus, so do not match on them
  or expect them in alert labels.
- `pg_database_wraparound_age_datfrozenxid_seconds` holds a transaction ID count despite its suffix.
- `pg_stat_activity_count` and `pg_stat_activity_max_tx_duration` carry `state`, `datname`, `usename`,
  `application_name`, `backend_type`, `wait_event_type` and `wait_event` labels; sum before dividing by
  `pg_settings_max_connections`, or the division matches nothing.
- `pg_replication_lag_seconds` (0.20.1) is 0 on a primary and on a replica that has replayed everything it
  received; otherwise it is the time since the last replayed transaction. A replica whose WAL receiver stopped
  receiving shows 0 too, so pair this rule with a check on the primary (`pg_stat_replication` rows, or
  `pg_replication_slots_active`).
- Page only on what needs a human within minutes (down, wraparound, archiving, slot WAL); send the rest to a ticket
  queue.
