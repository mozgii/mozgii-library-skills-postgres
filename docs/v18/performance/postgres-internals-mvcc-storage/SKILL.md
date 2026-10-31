---
name: postgres-internals-mvcc-storage
description: 'Shows how PostgreSQL 18 stores rows and decides which version a query sees, proved with pageinspect, pg_visibility and pg_freespacemap: the 8 kB heap page (header, line pointers, tuples), the tuple header (xmin, xmax, cmin, cmax, ctid, infomask and hint bits), transaction ids and the commit log, snapshots and visibility rules, HOT chains and page pruning, fillfactor, TOAST strategies and pglz versus lz4 compression, the free space map, the visibility map and index-only scans, and freezing in concept. Use when learning MVCC internals, asking why an UPDATE writes a new row, why a table grows, why index-only scans still visit the heap, how large values are stored, or reading heap_page_items output.'
metadata:
  tags:
  - postgres
  - internals
  - mvcc
  - heap
  - hot
  - toast
  - visibility-map
  - pageinspect
---

# PostgreSQL MVCC and storage internals

Every `UPDATE` writes a new row version and marks the old one with the updater's transaction id; every query decides
from its snapshot and the commit log which version it sees; vacuum later removes versions nobody can see. So:
update-heavy tables want free space on each page (`fillfactor`) and no indexes on the columns they update, which
keeps updates HOT; large values move to TOAST; and index-only scans are only as good as the visibility map, which
only vacuum sets. Concurrency rules for applications are in `postgres-transactions-locking`; vacuum operations,
bloat and wraparound in `postgres-vacuum-bloat`. TOAST and map detail:
[references/toast-and-maps.md](references/toast-and-maps.md).


## Step 0: read the server version, block size and checksum setting

Page sizes, hint-bit WAL and the inspection functions depend on how the server was built and created, so read them
first. A non-default `block_size` changes every byte count below.

```sql
SELECT current_setting('server_version') AS version, current_setting('block_size') AS block_size,
       current_setting('data_checksums') AS checksums, current_setting('wal_log_hints') AS wal_log_hints;
SELECT name, default_version, installed_version FROM pg_available_extensions
WHERE name IN ('pageinspect', 'pg_visibility', 'pg_freespacemap', 'dblink') ORDER BY name;
```

## Choosing a storage lever for a table that misbehaves

Most storage problems have one mechanism behind them, and the right lever depends on which one. Read the row that
matches what you see.

| You see | Mechanism | Lever | Why the obvious one loses |
|---|---|---|---|
| low `n_tup_hot_upd`, an index on an updated column | HOT needs no indexed column changed | remove that index or change the update | `fillfactor` cannot make such an update HOT |
| low `n_tup_hot_upd`, no such index, full pages | no room for the new version on the page | lower `fillfactor`, then rewrite the table | a new `fillfactor` only applies to pages written afterwards |
| high `Heap Fetches` on an index-only scan | pages not marked all-visible | vacuum the table more often | a `REINDEX` does not touch the map |
| a large value rewritten on every small change | TOAST stores the whole value again | move the changing part to its own row | compression still rewrites all chunks |
| the table grows while vacuum runs | an old snapshot keeps dead versions | end the long transaction | `VACUUM FULL` reclaims once and the growth returns |

## Setup for the examples

The examples were run in order on PostgreSQL 18.6 as a superuser (`pageinspect` needs one; `pg_visibility` and
`pg_freespacemap` need `pg_stat_scan_tables`). Autovacuum is off on the demo tables so pages stay as the examples
leave them.

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_visibility;
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE SCHEMA ms;
CREATE TABLE ms.acct (id int PRIMARY KEY, owner text, balance int) WITH (autovacuum_enabled = off);
INSERT INTO ms.acct VALUES (1, 'ana', 100), (2, 'bo', 200), (3, 'cy', 300);
```

## Heap page layout: header, line pointers and tuples

A table is a sequence of 8 kB pages. Each page starts with a 24-byte header, followed by an array of 4-byte line
pointers (item identifiers) growing forward; tuples are stored from the end of the page backward, and the free space
is the gap between `lower` (end of line pointers) and `upper` (start of tuples). A row's address, `ctid`, is
(page, line pointer), so a tuple can move inside its page without changing its address.

```sql
SELECT lower, upper, special, pagesize, prune_xid FROM page_header(get_raw_page('ms.acct', 0));
SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_hoff
FROM heap_page_items(get_raw_page('ms.acct', 0));
```

Here `lower = 36` (24-byte header plus 3 line pointers) and `upper = 8072` (three 40-byte slots from the end).
`lp_flags` is 1 normal, 2 redirect, 3 dead, 0 unused.

## The tuple header: xmin, xmax, cmin, cmax, ctid and infomask

Each tuple has a 23-byte header (padded, so data starts at `t_hoff = 24` here) that carries its visibility
information. The same fields are readable as hidden system columns.

| Field | Meaning |
|---|---|
| `xmin` | id of the transaction that inserted this version |
| `xmax` | id of the transaction that deleted or updated it, or locked it; 0 if none |
| `cmin` / `cmax` | command number inside the inserting / deleting transaction (one shared field) |
| `ctid` | this version's address, or the address of its newer version after an update |
| `t_infomask`, `t_infomask2` | flag bits: hint bits, `HEAP_HOT_UPDATED`, `HEAP_ONLY_TUPLE`, nulls present |

```sql
SELECT xmin, xmax, cmin, ctid, id, balance FROM ms.acct ORDER BY id;
SELECT t_ctid, raw_flags FROM heap_page_items(get_raw_page('ms.acct', 0)),
       LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);
```

## Transaction ids, the commit log and hint bits

A transaction gets a transaction id (xid) at its first write; read-only transactions never use one. An xid is 32
bits and wraps; `xid8` adds a 32-bit epoch and never wraps. Whether an xid committed is stored in the commit log,
`pg_xact`, at 2 bits per transaction (in progress, committed, aborted, sub-committed). Looking that up for every row
would be slow, so the first reader after commit sets hint bits (`HEAP_XMIN_COMMITTED`) on the tuple; this is why a
plain `SELECT` can dirty pages, and with data checksums on (the 18 default) write WAL.

```sql
CREATE TABLE ms.hint (id int);
INSERT INTO ms.hint VALUES (1);
SELECT t_xmin, raw_flags FROM heap_page_items(get_raw_page('ms.hint', 0)),
       LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);       -- {HEAP_XMAX_INVALID}
SELECT * FROM ms.hint;                                                   -- the first read sets the hint
SELECT t_xmin, raw_flags FROM heap_page_items(get_raw_page('ms.hint', 0)),
       LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2);       -- {HEAP_XMIN_COMMITTED,HEAP_XMAX_INVALID}
```

## Snapshots and visibility rules

A snapshot is `xmin:xmax:xip_list`: every xid below `xmin` had finished when it was taken, every xid at or above
`xmax` had not started, and `xip_list` holds those in progress between. A tuple version is visible to a snapshot,
in short, when its `xmin` committed and is not in the snapshot's future or in-progress list, and its `xmax` is empty,
aborted, or not yet committed for that snapshot. `READ COMMITTED` takes a snapshot per statement, `REPEATABLE READ`
one per transaction.

The proof uses `dblink` as a second session: a repeatable-read transaction keeps seeing `200` after another session
commits `999`, because the updater's xid is at or above the snapshot's `xmax`.

```sql
SELECT format('host=%s port=%s dbname=%s user=%s', split_part(current_setting('unix_socket_directories'), ',', 1),
              current_setting('port'), current_database(), current_user) AS conn \gset
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance, pg_current_snapshot() FROM ms.acct WHERE id = 2;              -- 200, e.g. 1046:1046:
SELECT dblink_exec(:'conn', 'UPDATE ms.acct SET balance = 999 WHERE id = 2'); -- other session, committed
SELECT xmin, xmax, ctid, balance, pg_xact_status(xmax::text::xid8) FROM ms.acct WHERE id = 2;   -- 200, xmax committed
COMMIT;
SELECT xmin, xmax, ctid, balance FROM ms.acct WHERE id = 2;                    -- 999 at a new ctid
```

Inside one transaction the command number separates statements, and a savepoint gets its own xid (a
subtransaction), recorded in `pg_subtrans`.

```sql
BEGIN;
INSERT INTO ms.hint VALUES (2);
INSERT INTO ms.hint VALUES (3);
SAVEPOINT s1;
INSERT INTO ms.hint VALUES (4);
SELECT xmin, cmin, id, pg_current_xact_id() AS top_xid FROM ms.hint WHERE id > 1;   -- id 4 has a new xmin
COMMIT;
```

## HOT updates, update chains and page pruning

An update is HOT (heap-only tuple) when no indexed column changes and the new version fits on the same page: the
index keeps pointing at the first version, which links through `t_ctid` to the newer ones on that page. Indexes are
not touched, and old versions can be removed during normal reads (page pruning) without vacuum. Three HOT updates of
row 1 build a chain; the index entry still points at `(0,1)`.

```sql
CREATE TABLE ms.hot (id int PRIMARY KEY, n int, note text) WITH (autovacuum_enabled = off);
INSERT INTO ms.hot SELECT g, 0, 'x' FROM generate_series(1, 10) g;
UPDATE ms.hot SET n = n + 1 WHERE id = 1;
UPDATE ms.hot SET n = n + 1 WHERE id = 1;
UPDATE ms.hot SET n = n + 1 WHERE id = 1;
SELECT lp, lp_flags, t_xmin, t_xmax, t_ctid FROM heap_page_items(get_raw_page('ms.hot', 0)) WHERE lp = 1 OR lp > 10;
SELECT itemoffset, htid FROM bt_page_items('ms.hot_pkey', 1) WHERE itemoffset = 1;            -- (0,1)
```

After pruning (here by `VACUUM`), line pointer 1 becomes a redirect (`lp_flags = 2`) to the live version and the
middle versions' slots become unused (0).

```sql
VACUUM ms.hot;
SELECT lp, lp_flags, lp_off, t_xmin, t_ctid FROM heap_page_items(get_raw_page('ms.hot', 0)) WHERE lp = 1 OR lp > 10;
```

Pruning also runs when a page is read or updated and its free space is low (under the fillfactor target or a tenth
of the page). A full page proves it: the redirect appears after a few updates with no vacuum.

```sql
CREATE TABLE ms.prune (id int PRIMARY KEY, n int) WITH (autovacuum_enabled = off);
INSERT INTO ms.prune SELECT g, 0 FROM generate_series(1, 220) g;           -- fills page 0
UPDATE ms.prune SET n = n + 1 WHERE id = 1;
UPDATE ms.prune SET n = n + 1 WHERE id = 1;
UPDATE ms.prune SET n = n + 1 WHERE id = 1;
UPDATE ms.prune SET n = n + 1 WHERE id = 1;
SELECT lp_flags, count(*) FROM heap_page_items(get_raw_page('ms.prune', 0)) GROUP BY 1 ORDER BY 1;   -- a 2 appears
```

## Fillfactor for update-heavy tables

`fillfactor` (100 for tables by default, 90 for B-tree indexes) leaves room on each page at insert time so later
updates can stay on the page and be HOT. The same 20,000-row update on two tables: none of the updates were HOT at
fillfactor 100, 8,398 at 70, for a table 12% larger.

```sql
CREATE TABLE ms.ff100 (id int PRIMARY KEY, n int, pad text) WITH (autovacuum_enabled = off);
CREATE TABLE ms.ff70  (id int PRIMARY KEY, n int, pad text) WITH (autovacuum_enabled = off, fillfactor = 70);
INSERT INTO ms.ff100 SELECT g, 0, repeat('p', 50) FROM generate_series(1, 20000) g;
INSERT INTO ms.ff70  SELECT g, 0, repeat('p', 50) FROM generate_series(1, 20000) g;
UPDATE ms.ff100 SET n = 1;
UPDATE ms.ff70  SET n = 1;
```

The counters are flushed when the session ends, so read them from a new session.

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd, pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname IN ('ff100', 'ff70') ORDER BY relname;
```

## TOAST in brief

TOAST stores large values: when a row is wider than about 2 kB (`TOAST_TUPLE_THRESHOLD`), PostgreSQL compresses
its `EXTENDED` columns and, if still too wide, moves values to the table's TOAST table in chunks of up to 1,996
bytes, until the row fits in about 2 kB (`toast_tuple_target`). An update that leaves a TOASTed value unchanged
does not rewrite it. Strategies, `pglz` versus `lz4` and proofs: [references/toast-and-maps.md](references/toast-and-maps.md).

## Why an index-only scan still visits the table: the visibility map

An index-only scan still visits the table (the heap) for every row on a page that the visibility map does not mark
all-visible, so the visibility map decides how many rows need a heap visit. The visibility map keeps two bits per heap
page: all-visible (no tuple needs vacuuming, all visible to everyone) and all-frozen. Only vacuum sets them; any change
to the page clears them. An index-only scan reads the heap page only when the page is not all-visible
(`Heap Fetches`). Updating 1% of rows cleared the bit on every page here, and the
same scan went from 0 heap fetches to 50,500.

```sql
CREATE TABLE ms.ios (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = off);
INSERT INTO ms.ios SELECT g, g FROM generate_series(1, 100000) g;
VACUUM (ANALYZE) ms.ios;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(id) FROM ms.ios WHERE id BETWEEN 1 AND 50000;                    -- Heap Fetches: 0
UPDATE ms.ios SET v = v + 1 WHERE id % 100 = 0;
SELECT count(*) FILTER (WHERE all_visible) AS visible_pages, count(*) AS pages FROM pg_visibility_map('ms.ios');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT count(id) FROM ms.ios WHERE id BETWEEN 1 AND 50000;                    -- Heap Fetches: 50500
```

## Freezing in concept

Because xids are 32 bits and compared modulo 2^32, a tuple older than about 2 billion transactions would seem to be
in the future. Vacuum prevents that by freezing old tuples: it sets `HEAP_XMIN_FROZEN` (the committed and invalid
hint bits together), which means "visible to everyone" regardless of `xmin`, and advances the table's
`relfrozenxid`. Freeze settings and wraparound emergencies are in `postgres-vacuum-bloat`.

```sql
VACUUM (FREEZE) ms.hot;
SELECT * FROM pg_visibility_map('ms.hot');                                      -- all_frozen = t
SELECT lp, t_xmin, combined_flags FROM heap_page_items(get_raw_page('ms.hot', 0)),
       LATERAL heap_tuple_infomask_flags(t_infomask, t_infomask2) WHERE lp IN (2, 3);   -- {HEAP_XMIN_FROZEN}
SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE oid = 'ms.hot'::regclass;
```

## Verify storage behaviour on your own tables

These read-only checks ran on 18.6 and show whether the levers above took effect. Read the counters from a new
session, because a session flushes its statistics when it ends.

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd, round(100.0 * n_tup_hot_upd / nullif(n_tup_upd, 0), 1) AS hot_pct,
       n_live_tup, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables WHERE schemaname = 'ms' ORDER BY n_tup_upd DESC;
SELECT * FROM pg_visibility_map_summary('ms.ios');             -- all_visible close to the table's pages
SELECT * FROM pg_check_visible('ms.hot');                      -- no rows: no tuple contradicts the map
```

After a `fillfactor` change, `hot_pct` must rise on new updates. After a vacuum, a repeat of the index-only scan must
show `Heap Fetches` near 0.

## Gotchas

These are the storage surprises seen most often, each with its cause and fix.

1. **A table doubles in size after a full-table `UPDATE`.** Every row got a new version; the old ones wait for vacuum.
   Update in batches with vacuum between, or rebuild (`postgres-vacuum-bloat`).
2. **Updates are never HOT.** An index covers an updated column, or pages are full. Drop the index if unused, or
   lower `fillfactor` and rewrite the table.
3. **Index-only scans show large `Heap Fetches`.** The visibility map is stale. Vacuum the table more often.
4. **A `SELECT` writes to disk and WAL.** It set hint bits for the first time. Expected after bulk loads; a
   `VACUUM` after the load does it once.
5. **`pg_stat_user_tables` shows 0 updates right after them.** Statistics are flushed at session end or by
   `pg_stat_force_next_flush()` and the next statement. Read from a new session.

## Anti-patterns in storage design

Each of these fights how the heap works.

| Do not | Do instead |
|---|---|
| Index a column that changes on every update | Keep frequently updated columns out of indexes, so updates stay HOT |
| Keep a counter inside a large `jsonb` document | Store the counter in its own column or row |
| Set `fillfactor` lower on a table that is only appended to | Leave it at 100; the free space would never be used |
| Run `UPDATE` on a whole big table in one statement | Update in batches with vacuum between them |
| Hold a transaction open for hours on a busy server | Keep transactions short: an old snapshot stops cleanup on every table |
| Read `heap_page_items` from application code | Keep `pageinspect` for diagnosis; it needs a superuser and shows raw pages |

## Checklist

Check these points when a table's storage behaviour matters.

- [ ] Hot update paths change no indexed column; `n_tup_hot_upd` confirms it.
- [ ] Update-heavy tables have `fillfactor` below 100.
- [ ] Large values that are updated in place are split out or kept small.
- [ ] Tables read with index-only scans are vacuumed often enough to keep pages all-visible.
- [ ] Long transactions are short: they keep old versions alive for every table.

## See also

Related skills in this library, each one works on its own:

- `postgres-vacuum-bloat`: vacuum operations, bloat and wraparound.
- `postgres-transactions-locking`: isolation levels and locks for applications.
- `postgres-internals-planner`: how the planner uses these structures.
- `postgres-internals-architecture`: processes, memory and the WAL.
- `postgres-indexing`: covering indexes and index-only scans.

## Sources

- https://www.postgresql.org/docs/18/storage-page-layout.html
- https://www.postgresql.org/docs/18/storage-hot.html
- https://www.postgresql.org/docs/18/storage-toast.html
- https://www.postgresql.org/docs/18/storage-fsm.html
- https://www.postgresql.org/docs/18/storage-vm.html
- https://www.postgresql.org/docs/18/transaction-id.html
- https://www.postgresql.org/docs/18/routine-vacuuming.html
- https://www.postgresql.org/docs/18/indexes-index-only-scans.html
- https://www.postgresql.org/docs/18/pageinspect.html
- https://www.postgresql.org/docs/18/pgvisibility.html
- https://www.postgresql.org/docs/18/pgfreespacemap.html
- https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/access/transam/clog.c
