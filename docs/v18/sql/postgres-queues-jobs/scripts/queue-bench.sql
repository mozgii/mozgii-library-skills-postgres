-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- pgbench script: claim up to :batch jobs with FOR UPDATE SKIP LOCKED and finish them by deleting them,
-- one transaction per batch. Fill jobs.job first, then for example:
--   pgbench -n -f queue-bench.sql -D batch=1   -c 8 -j 8 -T 10 <db>
--   pgbench -n -f queue-bench.sql -D batch=100 -c 8 -j 8 -T 10 <db>
-- Jobs per second = tps * batch. Run it against a scratch database, never production.
WITH next AS (
  SELECT id FROM jobs.job
  WHERE queue = 'default' AND state = 'ready' AND run_at <= now()
  ORDER BY priority DESC, run_at
  LIMIT :batch
  FOR UPDATE SKIP LOCKED
)
DELETE FROM jobs.job j USING next WHERE j.id = next.id;
