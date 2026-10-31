-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Replication slot health: WAL retained, consumer lag, invalidation, spills, and the settings that cap slots.
-- Usage: psql -X -v ON_ERROR_STOP=1 -f slot-health.sql   (read-only; run on the primary)
-- Tested on PostgreSQL 18.6.

\echo '== settings that cap or allow slots'
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('wal_level', 'max_replication_slots', 'max_wal_senders', 'max_slot_wal_keep_size',
               'idle_replication_slot_timeout', 'logical_decoding_work_mem', 'output_plugin_libraries',
               'synchronized_standby_slots', 'sync_replication_slots')
ORDER BY name;

\echo '== slots, worst first'
SELECT slot_name, slot_type, plugin, database, active, active_pid, wal_status,
       pg_size_pretty(safe_wal_size) AS safe_wal_left,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS consumer_lag,
       now() - inactive_since AS idle_for,
       invalidation_reason, failover, synced,
       age(catalog_xmin) AS catalog_xmin_age
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

\echo '== decoding spills and streaming per logical slot'
SELECT slot_name, spill_txns, pg_size_pretty(spill_bytes) AS spilled, stream_txns,
       total_txns, pg_size_pretty(total_bytes) AS decoded, stats_reset
FROM pg_stat_replication_slots
ORDER BY spill_bytes DESC;

\echo '== connected walsenders'
SELECT pid, usename, application_name, client_addr, state, sent_lsn, flush_lsn, replay_lsn, write_lag, flush_lag
FROM pg_stat_replication;
