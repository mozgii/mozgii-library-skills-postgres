---
title: Column encryption and password hashing with pgcrypto
author: MOZGII, Inc.
lang: en
---

# Column encryption and password hashing with pgcrypto

This reference covers encrypting individual columns with the `pgcrypto` extension on PostgreSQL 18.6: what it
protects against and what it does not, symmetric and public-key PGP encryption, searchable blind indexes, key
rotation, password hashing, and the 18.6 security fix. Every SQL example ran on 18.6 (pgcrypto 1.4); the public-key
example used a GnuPG 2.4 key made in a `postgres:18` container.

## Contents

The sections of this reference on pgcrypto:

1. What pgcrypto protects against
2. Symmetric PGP encryption of a column
3. Public-key encryption: write-only services
4. Blind indexes for equality search
5. Rotating encryption keys
6. Password hashing with crypt and gen_salt
7. Ciphers, OpenSSL 3, FIPS and the 18.6 fix
8. Keeping keys out of logs and statistics

## What pgcrypto protects against

pgcrypto runs inside the server: plaintext and keys travel to the server in the SQL call and exist in its memory.
The documentation's own advice is to connect locally or with TLS, trust the system and database administrators,
and otherwise encrypt in the client.

| Threat | pgcrypto in SQL | Encryption in the application with a KMS |
|---|---|---|
| stolen disk, snapshot, backup or replica | protects the encrypted columns | protects |
| SQL injection that reads tables | protects unless the attacker can also call decrypt with the key | protects |
| a DBA or superuser | does not protect (sees keys in queries, can trace calls) | protects |
| server logs, `pg_stat_activity`, monitoring | keys leak if passed as literals or logged parameters | nothing to leak |
| ability to filter or sort by the value in SQL | only equality through a blind index | only equality through a blind index |

Choose application-side envelope encryption (a data key per tenant or record, wrapped by a KMS key) when the
database staff must not read the data; choose pgcrypto when the goal is "encrypted at rest beyond disk encryption"
and the database is trusted at run time.

## Symmetric PGP encryption of a column

`pgp_sym_encrypt` produces an OpenPGP message (salted, with integrity check), so the same plaintext encrypts to
different bytes each time. Store it in `bytea`.

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE app.patients (
  id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name     text NOT NULL,
  ssn_enc  bytea NOT NULL,
  ssn_hmac bytea NOT NULL
);
INSERT INTO app.patients (name, ssn_enc, ssn_hmac)
VALUES ('Ada', pgp_sym_encrypt('123-45-6789', $1, 'cipher-algo=aes256, compress-algo=0, s2k-mode=3'),
        hmac('123-45-6789', $2, 'sha256'));
SELECT pgp_sym_decrypt(ssn_enc, $1) FROM app.patients WHERE id = 1;
SELECT pgp_key_id(ssn_enc) FROM app.patients;     -- SYMKEY for symmetric messages
```

Options: `cipher-algo` (`aes128` default, `aes192`, `aes256`), `compress-algo` (0 none, 1 zip, 2 zlib; turn
compression off for short secrets, since length after compression can leak content), `s2k-mode` (3 is salted and
iterated) and `s2k-count` (1024 to 65011712 iterations). `armor()` and `dearmor()` convert to and from ASCII
armour. The raw `encrypt()`/`decrypt()` functions have no integrity check or key derivation; the documentation
discourages them.

## Public-key encryption: write-only services

With `pgp_pub_encrypt`, services that store data hold only the public key; only the holder of the private key (an
offline job, a support tool) can decrypt. The key must have an encryption subkey: a key generated with only a
primary key fails with `No encryption key found`.

```bash
gpg --batch --passphrase '' --quick-gen-key 'Acme Data Key <data@acme.example>' rsa3072 sign never
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
gpg --batch --passphrase '' --quick-add-key "$FPR" rsa3072 encr never
gpg --armor --export "$FPR" > public.asc
```

Then load the public key into a psql variable and encrypt with it:

```sql
\set pub `cat public.asc`
INSERT INTO app.cards (card_enc) VALUES (pgp_pub_encrypt('4242 4242 4242 4242', dearmor(:'pub'), 'cipher-algo=aes256'));
SELECT pgp_pub_decrypt(card_enc, dearmor(:'sec')) FROM app.cards;     -- only where the secret key is loaded
```

A secret key protected by a passphrase is decrypted with `pgp_pub_decrypt(data, key, psw)`.

## Blind indexes for equality search

Encrypted values cannot be compared, so store a keyed hash next to them and search the hash. Use HMAC with a key
different from the encryption key, never a plain `digest()` (an attacker can hash every possible SSN).

```sql
CREATE INDEX patients_ssn_hmac_idx ON app.patients (ssn_hmac);
SELECT id FROM app.patients WHERE ssn_hmac = hmac('123-45-6789', $2, 'sha256');
```

Normalize before hashing (trim, case, remove separators), or equal values hash differently. A blind index reveals
which rows share a value; for low-cardinality data (a yes/no field, a country) it reveals the distribution.

## Rotating encryption keys

Key rotation re-encrypts each value: decrypt with the old key, encrypt with the new one, in batches so locks and
WAL stay small. Keep a key version column so old and new values can coexist during the run.

```sql
ALTER TABLE app.patients ADD COLUMN key_version int NOT NULL DEFAULT 1;
UPDATE app.patients
SET ssn_enc = pgp_sym_encrypt(pgp_sym_decrypt(ssn_enc, $1), $2, 'cipher-algo=aes256, compress-algo=0'),
    key_version = 2
WHERE id IN (SELECT id FROM app.patients WHERE key_version = 1 ORDER BY id LIMIT 1000);
```

Repeat until no row has `key_version = 1`, then retire the old key. Old backups still hold values under the old
key, so keep it as long as those backups are retained, and destroy it when they expire.

## Password hashing with crypt and gen_salt

`crypt()` with a salt from `gen_salt()` stores one-way password hashes; checking passes the stored hash as the salt.
PostgreSQL 18 adds `sha256crypt` and `sha512crypt` to `gen_salt` (default 5000 rounds, 1000 to 999,999,999), next
to `bf` (Blowfish-based bcrypt, default 6, 4 to 31).

```sql
SELECT crypt('correct horse', gen_salt('bf', 12)) AS hash \gset
SELECT crypt('correct horse', :'hash') = :'hash' AS password_ok;
SELECT gen_salt('sha512crypt', 100000);
```

Hashing in the database sends the plain password to the server, where `log_statement = 'all'` or a slow-query log
can record it; many teams hash in the application (Argon2id or bcrypt) and store the result. Never store
application passwords with `digest()` alone.

## Ciphers, OpenSSL 3, FIPS and the 18.6 fix

pgcrypto uses OpenSSL. With OpenSSL 3, old ciphers (DES, Blowfish, CAST5, 3DES, Twofish) need the legacy provider
enabled in `openssl.cnf`.

- Before 18.6 (and the matching minors of older branches), when OpenSSL refused such a cipher, PGP encryption
  silently produced output that was not really encrypted (CVE-2026-14663). From 18.6 the call fails; measured on
  18.6: `pgp_sym_encrypt(..., 'cipher-algo=bf')` raised `encrypt error: Cipher cannot be initialized`.
- Messages written by the faulty path fail to decrypt after the update. `pgp_sym_decrypt(data, key,
  'ignore-cipher-failure=1')` (also for `pgp_pub_decrypt`) restores the old behaviour only to recover and
  re-encrypt them, with the same OpenSSL configuration as when they were written.
- `fips_mode()` reports whether OpenSSL runs in FIPS mode; `pgcrypto.builtin_crypto_enabled = fips` disables
  `crypt()` and `gen_salt()` (which use built-in, non-OpenSSL code) when it does.

## Keeping keys out of logs and statistics

Keys reach the server as SQL values, so treat every place SQL is recorded as a leak path.

- Literals: `log_statement`, `log_min_duration_statement`, `auto_explain` and error messages print the statement
  text. Pass keys as bind parameters only.
- Bind parameters: slow-statement and error lines include parameter values unless `log_parameter_max_length = 0`
  and `log_parameter_max_length_on_error = 0` (the latter defaults to 0). Measured on 18.6: with the default -1,
  the log showed `Parameters: $1 = '<key>'`.
- `pg_stat_statements` normalizes constants to `$n`, so literal keys do not land in its query text; parameters are
  never stored there.
- `pg_stat_activity.query` shows the running statement's text, including literals, to the same role and to
  `pg_read_all_stats` members.
- pgaudit with `pgaudit.log_parameter = on` logs parameters; keep it off for tables touched by decrypt calls, or
  set `pgaudit.log_parameter_max_size`.
