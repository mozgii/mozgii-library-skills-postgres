-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
-- Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
-- Print one setval() per sequence so a logical-replication target can continue where the source stopped.
-- Logical replication does not copy sequence values. Run on the SOURCE after writes have stopped:
--   psql -X -At -d app -f sequences-setval.sql > setval.sql
-- then on the TARGET, before it takes writes:
--   psql -X -v ON_ERROR_STOP=1 -d app -f setval.sql
-- Covers serial and identity sequences. Sequences never used (last_value IS NULL) are skipped.
-- Adds a safety gap so ids handed out after the read cannot collide; set it with -v gap=1000 (default 1000).
\if :{?gap}
\else
  \set gap 1000
\endif
SELECT format('SELECT setval(%L, %s, true);',
              format('%I.%I', schemaname, sequencename),
              CASE WHEN increment_by > 0
                   THEN least(last_value + :gap * increment_by, max_value)
                   ELSE greatest(last_value + :gap * increment_by, min_value) END)
FROM pg_sequences
WHERE last_value IS NOT NULL
ORDER BY schemaname, sequencename;
