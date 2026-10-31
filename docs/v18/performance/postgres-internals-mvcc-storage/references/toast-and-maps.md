---
title: PostgreSQL TOAST storage, compression, and the free space and visibility maps
author: MOZGII, Inc.
lang: en
---

# PostgreSQL TOAST storage, compression, and the free space and visibility maps

This reference shows how PostgreSQL 18 stores large column values (TOAST), how `pglz` and `lz4` compression compare,
and what the free space map and visibility map hold. It continues the `postgres-internals-mvcc-storage` skill; run
its setup block first. Every result in the comments is from PostgreSQL 18.6.

## When TOAST applies: thresholds and chunks

TOAST (The Oversized-Attribute Storage Technique) applies to variable-length types (`text`, `bytea`, `jsonb`,
arrays). It is triggered when a row is wider than `TOAST_TUPLE_THRESHOLD` (normally 2 kB); PostgreSQL then
compresses and moves values out of line until the row is under `TOAST_TUPLE_TARGET` (normally 2 kB, per table
`toast_tuple_target`). Out-of-line values are split into chunks of at most `TOAST_MAX_CHUNK_SIZE` (about 2,000
bytes, so four fit on a page) stored as rows of the table's TOAST table, and one value is at most 1 GB.

```sql
CREATE TABLE ms.docs (id int PRIMARY KEY, body text);
INSERT INTO ms.docs VALUES
  (1, repeat('a', 1500)),                                                  -- under 2 kB: stays inline, raw
  (2, repeat('a', 100000)),                                                -- compressible: compressed inline
  (3, (SELECT string_agg(md5(i::text), '') FROM generate_series(1, 400) AS s(i)));   -- hex: out of line
SELECT id, octet_length(body) AS raw_bytes, pg_column_size(body) AS stored_bytes,
       pg_column_compression(body) AS method, pg_column_toast_chunk_id(body) AS chunk_id
FROM ms.docs ORDER BY id;     -- 1: 1504, -   2: 1156, pglz   3: 12800, -, chunk id
SELECT reltoastrelid::regclass AS toast FROM pg_class WHERE oid = 'ms.docs'::regclass \gset
SELECT chunk_id, count(*) AS chunks, sum(octet_length(chunk_data)) AS bytes, max(octet_length(chunk_data)) AS max_chunk
FROM :toast GROUP BY chunk_id;                                             -- 7 chunks, 12800 bytes, max 1996
```

`pg_column_toast_chunk_id` is PostgreSQL 17+. The hexadecimal text did not compress: `pglz` gives up when it saves
too little, and hex digits have no repeated sequences for it to find.

## TOAST strategies: PLAIN, EXTENDED, EXTERNAL and MAIN

Each column has a storage strategy (`attstorage`), set with `ALTER TABLE ... ALTER COLUMN ... SET STORAGE`; a new
setting applies to values written afterwards.

| Strategy | `attstorage` | Compress | Out of line | Use |
|---|---|---|---|---|
| `PLAIN` | `p` | no | no | fixed-length types such as `int` |
| `EXTENDED` | `x` | yes, first | yes | default for `text`, `bytea`, `jsonb` |
| `EXTERNAL` | `e` | no | yes | large text read with `substring`: only the needed chunks are fetched |
| `MAIN` | `m` | yes | only as a last resort | values that should stay in the row |

## Compression: pglz versus lz4

`default_toast_compression` is `pglz`; `lz4` is available when the server was built with `--with-lz4` (Postgres.app,
the Debian packages and the Docker image are). `lz4` is faster to compress and decompress; ratios depend on the
data. Set it per column or as the default.

```sql
ALTER TABLE ms.docs ALTER COLUMN body SET COMPRESSION lz4;
INSERT INTO ms.docs VALUES (4, repeat('a', 100000));
ALTER TABLE ms.docs ALTER COLUMN body SET STORAGE EXTERNAL;
INSERT INTO ms.docs VALUES (5, repeat('a', 100000));
SELECT id, pg_column_size(body) AS stored_bytes, pg_column_compression(body) AS method,
       pg_column_toast_chunk_id(body) IS NOT NULL AS out_of_line
FROM ms.docs WHERE id IN (2, 4, 5) ORDER BY id;     -- 2: 1156 pglz   4: 411 lz4   5: 100000 uncompressed, out of line
SELECT attname, attstorage, attcompression FROM pg_attribute
WHERE attrelid = 'ms.docs'::regclass AND attname = 'body';                  -- e, l
```

`SET COMPRESSION` applies to values compressed from then on. Only a changed value is compressed again: on 18.6,
after switching a column from `pglz` to `lz4`, `UPDATE ... SET body = body`, an update of another column, `VACUUM
FULL`, `CLUSTER` and `INSERT ... SELECT` into a new table all kept `pglz`, and only `SET body = body || 'z'` produced
`lz4`. A `pg_restore` writes every value with the column's configured method (the `ALTER TABLE` docs say so).

## Updates and TOASTed values

An `UPDATE` that does not change a TOASTed value copies only its pointer: the new row version points to the same
chunks. Changing the value writes all of it again, which is why a counter inside a large document is expensive.

```sql
SELECT pg_column_toast_chunk_id(body) AS before FROM ms.docs WHERE id = 3;
UPDATE ms.docs SET id = 30 WHERE id = 3;
SELECT pg_column_toast_chunk_id(body) AS same_chunks FROM ms.docs WHERE id = 30;
UPDATE ms.docs SET body = body || 'z' WHERE id = 30;
SELECT pg_column_toast_chunk_id(body) AS new_chunks FROM ms.docs WHERE id = 30;
```

## The free space map

The free space map (FSM, file `<relfilenode>_fsm`) records free space per page so inserts find room without
scanning. It stores one byte per page, so values are rounded to 1/256 of the page (32 bytes), and it is updated
mainly by vacuum, so it lags behind recent changes. Hash indexes have none.

```sql
SELECT * FROM pg_freespace('ms.hot');                     -- blkno, avail after the VACUUM in the skill
SELECT count(*) AS pages, sum(avail) AS free_bytes FROM pg_freespace('ms.ios');
```

## The visibility map in detail

The visibility map (file `<relfilenode>_vm`) holds two bits per heap page: all-visible and all-frozen. Vacuum sets
them; any insert, update or delete on the page clears them. They let vacuum skip pages, let index-only scans skip
the heap, and let an aggressive (anti-wraparound) vacuum skip all-frozen pages. `pg_visibility` also compares the
map with the page-level flag `PD_ALL_VISIBLE` and can check that a page marked all-visible truly is.

```sql
SELECT blkno, all_visible, all_frozen, pd_all_visible FROM pg_visibility('ms.hot');
SELECT * FROM pg_visibility_map_summary('ms.ios');
SELECT * FROM pg_check_visible('ms.hot');                 -- no rows: no tuple contradicts the map
```

## Sources

- https://www.postgresql.org/docs/18/storage-toast.html
- https://www.postgresql.org/docs/18/sql-altertable.html
- https://www.postgresql.org/docs/18/runtime-config-client.html
- https://www.postgresql.org/docs/18/functions-admin.html
- https://www.postgresql.org/docs/18/storage-fsm.html
- https://www.postgresql.org/docs/18/storage-vm.html
- https://www.postgresql.org/docs/18/pgfreespacemap.html
- https://www.postgresql.org/docs/18/pgvisibility.html
