---
title: Testing and debugging PostgreSQL functions
author: MOZGII, Inc.
lang: en
---

# Testing and debugging PostgreSQL functions

This reference lists the settings and habits that find mistakes in PL/pgSQL functions and triggers.

## Testing and debugging functions

Database code needs the same tests as application code, run against a real server.

- `SET plpgsql.extra_warnings = 'all';` (or `extra_errors`) reports shadowed variables and other mistakes at
  creation time.
- `RAISE NOTICE 'x = %', x;` prints to the client during development.
- `SET track_functions = 'pl';` then `pg_stat_user_functions` shows calls and time per function.
- `auto_explain.log_nested_statements = on` logs the plans of queries inside functions.
- Test triggers in a transaction that rolls back: perform the write, assert on the audit or derived rows, `ROLLBACK`.
