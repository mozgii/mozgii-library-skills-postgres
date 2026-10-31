---
title: PostgreSQL deferrable constraints
author: MOZGII, Inc.
lang: en
---

# PostgreSQL deferrable constraints

This reference covers deferrable UNIQUE, PRIMARY KEY, EXCLUDE and foreign key constraints: statement-level uniqueness, SET CONSTRAINTS, circular foreign keys and the costs, as run on PostgreSQL 18.6.

## Deferrable constraints and SET CONSTRAINTS

A deferrable constraint can be checked at commit instead of after each statement, which allows swaps and circular
references. Only `UNIQUE`, `PRIMARY KEY`, `EXCLUDE` and foreign keys can be deferrable; `NOT NULL` and `CHECK` cannot.
A non-deferrable unique constraint is checked row by row, so `SET position = 3 - position` fails halfway; declared
`DEFERRABLE INITIALLY IMMEDIATE` it is checked at the end of the statement and the swap succeeds:

```sql
CREATE TABLE app.playlist_items (
  playlist_id bigint NOT NULL,
  position    int NOT NULL,
  track_id    bigint NOT NULL,
  CONSTRAINT playlist_items_position_uq UNIQUE (playlist_id, position) DEFERRABLE INITIALLY IMMEDIATE
);
UPDATE app.playlist_items SET position = 3 - position WHERE playlist_id = 1;   -- swaps 1 and 2

BEGIN;
SET CONSTRAINTS app.playlist_items_position_uq DEFERRED;     -- now checked at COMMIT
UPDATE app.playlist_items SET position = 10 WHERE track_id = 100;
UPDATE app.playlist_items SET position = 1  WHERE track_id = 200;
UPDATE app.playlist_items SET position = 2  WHERE track_id = 100;
COMMIT;
```

Circular foreign keys (a team needs a captain, the captain belongs to the team) need both to be
`DEFERRABLE INITIALLY DEFERRED`, then both rows go in one transaction. Costs: a deferrable unique constraint is slower
than an immediate one, it cannot be an `ON CONFLICT` arbiter (`55000`), and a deferred violation surfaces at `COMMIT`,
where application code must expect it.


## Circular foreign keys with deferred checks

Circular foreign keys need both constraints `DEFERRABLE INITIALLY DEFERRED`, then both rows go in one transaction.
This pair lets a team name its captain while the captain row names the team:

```sql
CREATE TABLE app.teams (id bigint PRIMARY KEY, captain_id bigint NOT NULL);
CREATE TABLE app.players (
  id      bigint PRIMARY KEY,
  team_id bigint NOT NULL REFERENCES app.teams DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE app.teams ADD CONSTRAINT teams_captain_fk
  FOREIGN KEY (captain_id) REFERENCES app.players DEFERRABLE INITIALLY DEFERRED;
BEGIN;
INSERT INTO app.teams VALUES (1, 10);
INSERT INTO app.players VALUES (10, 1);
COMMIT;
```

## Deferred violations surface at COMMIT

A deferred violation is reported by `COMMIT`, not by the statement that caused it: the transaction runs on, then
`COMMIT` fails with `23505` (or `23503`) and everything rolls back. Code that commits through a framework must treat
an error from `COMMIT` like any other database error.
