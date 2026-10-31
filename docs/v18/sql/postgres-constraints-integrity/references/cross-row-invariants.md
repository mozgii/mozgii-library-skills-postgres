---
title: "PostgreSQL invariants across rows: write skew, SERIALIZABLE and parent-row locks"
author: MOZGII, Inc.
lang: en
---

# PostgreSQL invariants across rows: write skew, SERIALIZABLE and parent-row locks

This reference reproduces write skew on PostgreSQL 18.6 and proves the two fixes for rules that compare many rows, such as "at least one doctor stays on call".

## Invariants across rows: SERIALIZABLE or a parent-row lock

Some rules compare an aggregate ("at least one doctor stays on call for each shift") and no constraint expresses
them. Under `READ COMMITTED` two transactions each see two doctors on call, each takes one off, and both commit: zero
remain (write skew, reproduced on 18.6 with two `dblink` sessions). Two fixes, both proven:

- Run the transaction `SERIALIZABLE`: the second commit fails with `40001 could not serialize access`, a
  read/write dependency failure, and the client retries (`postgres-transactions-locking`).
- Lock one parent row that stands for the rule, so writers to the same shift queue up and the second one sees the
  first one's change:

```sql
CREATE FUNCTION app.go_off_call(p_doctor text, p_shift int) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM app.shifts WHERE id = p_shift FOR UPDATE;          -- serialize changes per shift
  IF (SELECT count(*) FROM app.on_call WHERE shift_id = p_shift AND on_call) < 2 THEN
    RETURN false;                                                     -- would leave nobody on call
  END IF;
  UPDATE app.on_call SET on_call = false WHERE doctor = p_doctor AND shift_id = p_shift;
  RETURN true;
END $$;
```

Choose `SERIALIZABLE` when many rules of this kind exist and the code already retries; choose the parent lock for
one hot rule where retries are costly. A deferred constraint trigger (`postgres-functions-triggers`) alone is not
race-free under `READ COMMITTED`.


## Reproducing write skew with dblink

Write skew can be shown in one psql script with two `dblink` sessions, `a` and `b`, in a scratch database. Each
transaction counts two doctors on call and takes one off. Under `READ COMMITTED` both commit and zero remain; with
`BEGIN ISOLATION LEVEL SERIALIZABLE` in both sessions the second `COMMIT` fails and one doctor remains:

```sql
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TABLE app.on_call (doctor text PRIMARY KEY, shift_id int NOT NULL, on_call boolean NOT NULL);
INSERT INTO app.on_call VALUES ('alice', 1, true), ('bob', 1, true);
SELECT dblink_connect('a', 'host=/tmp/pg port=5432 dbname=scratch');
SELECT dblink_connect('b', 'host=/tmp/pg port=5432 dbname=scratch');
SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT dblink_exec('b', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('a', 'SELECT count(*) FROM app.on_call WHERE shift_id = 1 AND on_call') AS t(n bigint);
SELECT * FROM dblink('b', 'SELECT count(*) FROM app.on_call WHERE shift_id = 1 AND on_call') AS t(n bigint);
SELECT dblink_exec('a', $$UPDATE app.on_call SET on_call = false WHERE doctor = 'alice'$$);
SELECT dblink_exec('b', $$UPDATE app.on_call SET on_call = false WHERE doctor = 'bob'$$);
SELECT dblink_exec('a', 'COMMIT');
SELECT dblink_exec('b', 'COMMIT', false) AS b_commit, dblink_error_message('b');
-- b_commit = ERROR: could not serialize access due to read/write dependencies among transactions
```

The parent-lock version is proven the same way with `dblink_send_query`: while session `a` holds the shift row,
`dblink_is_busy('b')` returns 1 (b waits), and after `a` commits, b's call returns `false`.
