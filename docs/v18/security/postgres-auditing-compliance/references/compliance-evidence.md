---
title: PostgreSQL compliance evidence, erasure and retention runbooks
author: MOZGII, Inc.
lang: en
---

# PostgreSQL compliance evidence, erasure and retention runbooks

This reference lists the evidence auditors usually request about a PostgreSQL estate for SOC 2 and ISO 27001
style audits, and gives the runbooks for personal data erasure (GDPR right to erasure) and data retention. Control
names below are written as themes, not quoted control IDs: map them to your framework's identifiers with your
auditor. All SQL was run on PostgreSQL 18.6.

## Contents

The sections of this reference on compliance:

1. Evidence auditors ask for, by control theme
2. Producing access review evidence
3. GDPR erasure runbook
4. Erasure ledger table and replay after restore
5. Crypto-shredding and where its keys must live
6. Data retention policy and enforcement
7. Masking for non-production copies

## Evidence auditors ask for, by control theme

Auditors test that a control exists (design) and that it worked over the period (operating effectiveness), so keep
dated artefacts, not only configuration.

| Control theme | What they ask | PostgreSQL evidence |
|---|---|---|
| access control and least privilege | who can read, write, administer | role and grant listings, `pg_hba_file_rules`, quarterly review sign-off |
| privileged access | who is superuser, how use is approved and logged | `rolsuper` list, break-glass procedure, connection and audit logs of those sessions |
| authentication | password storage, MFA or certificates, no shared accounts | `password_encryption`, no md5 hashes, `cert`/SSO methods, personal login roles |
| logging and monitoring | what is logged, where, how long, who reviews | `pg_settings` for logging and `pgaudit.*`, log shipping config, retention, alert rules |
| encryption | in transit and at rest | `ssl` settings, `hostssl` rules, `pg_stat_ssl` sample, volume or KMS encryption settings |
| change management | schema changes reviewed and traceable | migrations in version control, DDL audit (pgaudit `ddl` or event trigger table) |
| backup and recovery | backups run, are protected, restores tested | backup job history, restore drill records with dates and timings |
| data deletion and retention | personal data removed on request and on schedule | erasure ledger, partition drop jobs, backup retention configuration |
| data masking | production data not used raw in test | masking rules (`SECURITY LABEL FOR anon`), masked dump procedure |
| vulnerability and patch management | supported versions, timely minor updates | `SELECT version()` per server against the release calendar |

## Producing access review evidence

An access review is a dated export of who has which rights, reviewed and signed by an owner. These queries produce
the export; save the output with the date and the reviewer's decision.

```sql
SELECT current_setting('server_version') AS version, now() AS taken_at;
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication, rolcanlogin, rolvaliduntil
FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY 1;
SELECT r.rolname AS member, g.rolname AS granted_role, m.admin_option, m.inherit_option, m.set_option
FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member JOIN pg_roles g ON g.oid = m.roleid ORDER BY 1, 2;
SELECT grantee, table_schema, table_name, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
SELECT line_number, type, database, user_name, address, auth_method, options FROM pg_hba_file_rules;
```

## GDPR erasure runbook

An erasure request removes a person's personal data everywhere the organization controls it, within the legal
deadline, and leaves proof without keeping the data. For a PostgreSQL-backed system:

1. Find every place the subject's data lives: tables keyed by the subject id, free-text columns, JSONB documents,
   search indexes, caches, analytics copies, CDC consumers and exports. Keep this map in the data inventory.
2. Delete in one transaction in the primary database: rows referencing the subject (`ON DELETE CASCADE` or
   explicit deletes in child-first order), then the subject row; or anonymize rows that must stay for accounting
   (replace name and contact fields, keep amounts).
3. Record the erasure in the ledger in the same transaction, storing a keyed hash of the subject id, never the id
   or personal data in clear.
4. Let replicas and logical replication carry the delete; confirm downstream systems (CDC topics, warehouses)
   apply deletes or run their own erasure.
5. Logs: server and audit logs may hold the subject's data in statement text or parameters; their retention period
   must be within the policy, or they need their own redaction process.
6. Backups: they are not edited. Document the backup retention, and replay the ledger after every restore.
7. Answer the requester with what was deleted, what was retained and why (legal hold, accounting), and when backups
   holding the data expire.

## Erasure ledger table and replay after restore

The ledger lets a restored database be brought back into compliance before it serves traffic. This was run on
18.6 (`$1` is the HMAC key, held by the application, not in the database):

```sql
CREATE TABLE audit.erasure_ledger (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  subject_hash bytea NOT NULL UNIQUE,
  requested_at timestamptz NOT NULL,
  erased_at    timestamptz NOT NULL DEFAULT now(),
  erased_by    name NOT NULL DEFAULT session_user,
  tables       text[] NOT NULL
);

BEGIN;
DELETE FROM app.people WHERE id = 42;
INSERT INTO audit.erasure_ledger (subject_hash, requested_at, tables)
VALUES (hmac('42', $1, 'sha256'), '2026-10-20', ARRAY['app.people', 'app.people_orders']);
COMMIT;

-- after a restore: subjects that came back, then delete them the same way
SELECT p.id FROM app.people p
JOIN audit.erasure_ledger e ON e.subject_hash = hmac(p.id::text, $1, 'sha256');
```

The ledger itself must survive restores: keep a copy outside the database's backups (an append-only store), since
restoring last week's backup also restores last week's ledger. `hmac()` needs `pgcrypto`.

## Crypto-shredding and where its keys must live

Crypto-shredding encrypts each subject's data with a per-subject key and erases the subject by destroying the key,
which also makes the data in old backups unreadable. It works only if the keys are not in those backups:

- Keys in a table of the same database are restored with it; that is not shredding.
- Keys in a KMS or a separate key store with short (or no) backups make shredding real.
- Encryption must happen in the application or with keys fetched per request; plaintext passing through SQL lands
  in logs as described in `postgres-encryption-tls`.

## Data retention policy and enforcement

Retention rules say how long each data class is kept; enforcement should be a scheduled job, with its runs logged.

| Data class | Typical mechanism |
|---|---|
| event, access and audit tables | range partitions by month; detach and drop expired partitions |
| business records with a legal minimum | keep, then anonymize fields on schedule |
| server and audit logs | retention in the log store (object lock duration), not on the database host |
| backups and WAL archives | retention in the backup tool (pgBackRest `repo1-retention-full`), documented |

Dropping a partition is instant and leaves no bloat; `DETACH PARTITION ... CONCURRENTLY` avoids blocking writers
and cannot run in a transaction block or when the table has a default partition.

```sql
ALTER TABLE audit.access_log DETACH PARTITION audit.access_log_2026_09 CONCURRENTLY;
DROP TABLE audit.access_log_2026_09;
```

## Masking for non-production copies

Copies of production for development, testing or analytics must not carry personal data unless that use is
covered. Options, from weakest to strongest guarantee:

- Dynamic masking with PostgreSQL Anonymizer: masked roles see masked values in the live database.
- Masked dump: `pg_dump --no-security-labels --exclude-extension=anon` as a masked role, restored elsewhere.
- Static masking: `anon.anonymize_database()` or per-table rules applied to a copy, destroying the originals there.
- Synthetic data generated from the schema, which avoids copying personal data at all.

Masking is not anonymization in the legal sense when records can be re-identified (rare combinations of
birth date, postcode and gender); pseudonymized data stays personal data.
