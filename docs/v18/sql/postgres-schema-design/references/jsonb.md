---
title: JSONB patterns in PostgreSQL
author: MOZGII, Inc.
lang: en
---

# JSONB patterns in PostgreSQL

This reference covers when to store data as JSONB, how to query it, and which index serves which JSONB operator.

## When JSONB fits and when it does not

JSONB fits data the database stores and returns whole: third-party payloads, per-tenant settings, form answers,
audit snapshots. It does not fit fields you filter, join, sort, aggregate or constrain on every query: those belong in
typed columns, where the planner has statistics and constraints apply. A common shape is typed columns for the
fields queries use, plus one `jsonb` column for the rest.

## Querying JSONB with operators and jsonpath

JSONB operators read keys, test containment and run jsonpath expressions.

```sql
SELECT payload->>'event'          AS event,      -- text
       payload->'user'->>'id'     AS user_id,    -- nested key as text
       (payload->>'amount')::numeric AS amount
FROM app.webhooks
WHERE payload @> '{"event": "invoice.paid"}'              -- containment: uses a GIN index
  AND payload @? '$.lines[*] ? (@.amount > 100)';         -- jsonpath: GIN narrows on ==, this > rechecks each row
```

- `->` returns `jsonb`, `->>` returns `text`. Compare `->>` results to text, or cast.
- `payload['user']['id']` subscripting works for reads and `UPDATE ... SET payload['k'] = '"v"'`.
- `jsonb_set(col, '{a,b}', '"v"')` updates one path; `col || '{"k": 1}'` merges at the top level; `col - 'k'` removes
  a key.
- `JSON_TABLE` (PG 17+) turns a JSON array into rows with typed columns.

## JSONB indexes: GIN default, jsonb_path_ops and expression indexes

The right JSONB index depends on the operator the query uses.

```sql
CREATE INDEX webhooks_payload_gin ON app.webhooks USING gin (payload jsonb_path_ops);   -- @>, @?, @@ only; smaller
CREATE INDEX webhooks_payload_gin_all ON app.webhooks USING gin (payload);              -- also ?, ?|, ?& (key exists)
CREATE INDEX webhooks_event_idx ON app.webhooks ((payload->>'event'));                  -- B-tree: =, <, ORDER BY
```

- `jsonb_path_ops` is smaller and faster for containment but does not support the key-exists operators `?`, `?|`, `?&`.
- A query written `payload->>'event' = 'x'` cannot use a GIN index; it needs the expression B-tree above. Rewrite it
  as `payload @> '{"event":"x"}'` to use GIN.
- If one key is queried constantly, promote it to a column (a `STORED` generated column works:
  `event text GENERATED ALWAYS AS (payload->>'event') STORED`).

## Validating JSONB shape

JSONB accepts any JSON, so add the checks the application relies on.

```sql
ALTER TABLE app.webhooks ADD CONSTRAINT webhooks_payload_is_object
  CHECK (jsonb_typeof(payload) = 'object' AND payload ? 'event');
```

## JSONB gotchas

These JSONB problems come up most often, each with its cause and fix.

1. **Large JSONB values are slow to update.** Each update writes a new copy of the whole value (TOAST), so a 1 MB
   document with a counter inside rewrites 1 MB per increment. Keep hot fields in columns.
2. **`->>` comparisons are text comparisons.** `'10' < '9'` is true. Cast: `(payload->>'n')::int < 9`.
3. **No statistics on keys.** The planner guesses selectivity for JSONB predicates. An expression index gives it
   statistics for that expression after `ANALYZE`.
4. **`json` instead of `jsonb`.** `json` keeps the original text and is re-parsed on every access; it has no GIN
   support.
