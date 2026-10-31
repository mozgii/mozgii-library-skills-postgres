---
name: postgres-encryption-tls
description: 'Encrypts PostgreSQL 18 data in transit and at rest: server TLS setup (certificates, key permissions, ssl_min_protocol_version, ssl_groups and ssl_tls13_ciphers in 18, reload-based rotation), pg_hba hostssl rules, client sslmode=verify-full and sslrootcert=system, sslnegotiation=direct, client certificate authentication (cert method, clientcert=verify-full, pg_ident maps), SCRAM with channel binding and moving off md5 (deprecated in 18), pgcrypto column encryption and its key-handling limits, and encryption at rest with disk encryption, cloud KMS or TDE forks. Use when turning on TLS, a client fails certificate verification, an auditor asks whether connections and data are encrypted, migrating md5 passwords, or encrypting a sensitive column.'
metadata:
  tags:
  - postgres
  - tls
  - ssl
  - encryption
  - certificates
  - scram
  - channel-binding
  - pgcrypto
  - encryption-at-rest
  - md5
---

# PostgreSQL encryption: TLS, SCRAM and data at rest

Encrypt every TCP connection and make clients check who they talk to: server TLS on, `hostssl` lines only plus a
`hostnossl ... reject`, and clients on `sslmode=verify-full`. Authenticate with SCRAM (with `channel_binding=require`
on clients that support it) or client certificates; retire md5. For data at rest, use volume or disk encryption (or
the cloud provider's KMS-backed storage); reach for `pgcrypto` only for a few columns that must stay unreadable to
people with database access, and know that its keys pass through the server. Roles, `pg_hba.conf` basics and
row-level security are in `postgres-security-roles`; backup encryption is in `postgres-backup-restore`. The commands
for a test CA are under Server TLS setup and packaged as [scripts/make-test-ca.sh](scripts/make-test-ca.sh). Column
encryption in depth:
[references/pgcrypto-column-encryption.md](references/pgcrypto-column-encryption.md).

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Step 0: see what is encrypted today

Read the server's TLS settings, which connections use TLS now, which `pg_hba.conf` rules allow plain TCP, and which
roles still have md5 hashes.

```sql
SELECT name, setting FROM pg_settings WHERE name ~ '^ssl' OR name IN ('password_encryption', 'scram_iterations');
SELECT a.usename, a.client_addr, s.ssl, s.version, s.cipher, s.client_dn
FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.client_addr IS NOT NULL;
SELECT line_number, type, database, user_name, address, auth_method, options, error FROM pg_hba_file_rules;
SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'md5%';          -- superuser only
```

18.6 defaults: `ssl` off, `ssl_min_protocol_version` TLSv1.2, `ssl_groups` `X25519:prime256v1`,
`ssl_tls13_ciphers` empty (OpenSSL's default set), `password_encryption` scram-sha-256, `scram_iterations` 4096.

## Server TLS setup

The server needs a certificate, its private key and (for client certificates) the CA file. The key must be readable
only by the server's OS user (mode 0600), or owned by root with mode 0640; the server refuses looser permissions.

```ini
# postgresql.conf (all of these take effect on reload)
ssl = on
ssl_cert_file = '/etc/postgresql/tls/server.crt'   # server certificate first, then intermediates
ssl_key_file = '/etc/postgresql/tls/server.key'
ssl_ca_file = '/etc/postgresql/tls/ca.crt'         # CAs trusted for client certificates
ssl_min_protocol_version = 'TLSv1.3'               # default TLSv1.2; raise when every client supports 1.3
ssl_groups = 'X25519:secp384r1'                    # PG 18 name; was ssl_ecdh_curve with one value
ssl_tls13_ciphers = 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256'   # PG 18; TLS 1.3 suites
```

### A test CA and certificates with OpenSSL

For test and staging, these OpenSSL 3 commands make a private CA, a server certificate and a client certificate.
Production certificates come from your organization's CA or a managed PKI. `verify-full` checks the names in
`subjectAltName`, and the client certificate's CN must equal the role or match a `pg_ident.conf` map.

```bash
umask 077
openssl req -x509 -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
  -subj "/CN=Test Postgres Root CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -keyout ca.key -out ca.crt

openssl req -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -subj "/CN=db1.acme.internal" \
  -addext "subjectAltName=DNS:db1.acme.internal,DNS:localhost,IP:127.0.0.1" -keyout server.key -out server.csr
printf 'extendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 397 \
  -copy_extensions copy -extfile server.ext -out server.crt

openssl req -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -subj "/CN=app_api" \
  -keyout app_api.key -out app_api.csr
printf 'extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' > client.ext
openssl x509 -req -in app_api.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 \
  -extfile client.ext -out app_api.crt

openssl verify -CAfile ca.crt server.crt app_api.crt
```

### Certificate files and rotation

- Put the certificate files outside the data directory when the data directory allows group read (for backups),
  so the key keeps strict permissions.
- Rotation: replace the files and `SELECT pg_reload_conf();`. New connections use the new certificate; a file
  error at reload keeps the old configuration (and is logged), while an error at start stops the server.
- A passphrase-protected key needs `ssl_passphrase_command`, and by default then blocks reloads
  (`ssl_passphrase_command_supports_reload`).
- On Windows the server re-reads the files for each new connection; the settings are the same.

## pg_hba.conf rules that require TLS

`hostssl` matches only TLS connections and `hostnossl` only plain ones, so a final reject for `hostnossl` (or for
`host` after all `hostssl` lines) guarantees nothing authenticates in clear text. This file was loaded on 18.6:

```text
# TYPE    DATABASE  USER       ADDRESS       METHOD
local     all       all                      peer
hostssl   all       app_api    0.0.0.0/0     cert  map=svc
hostssl   all       app_pw     0.0.0.0/0     scram-sha-256  clientcert=verify-full
hostssl   all       app_scram  0.0.0.0/0     scram-sha-256
host      all       all        0.0.0.0/0     reject
```

A plain connection then fails with `pg_hba.conf rejects connection for host "...", user "...", database "...", no
encryption`. Check the parsed rules after every edit with `pg_hba_file_rules` (the `error` column).

## Client sslmode, verify-full and sslrootcert=system

The client decides whether the server's certificate is checked. Only `verify-full` checks both the CA and that the
host name matches the certificate; anything weaker allows a man in the middle.

| `sslmode` | Encrypts | Checks CA | Checks host name |
|---|---|---|---|
| `disable`, `allow` | no / maybe | no | no |
| `prefer` (libpq default) | if the server offers it | no | no |
| `require` | yes | only if a root CA file is present | no |
| `verify-ca` | yes | yes | no |
| `verify-full` | yes | yes | yes (DNS subjectAltNames; CN only when there is none) |

Two client connections: one to a server with a private CA, one to a service with a publicly trusted certificate:

```bash
psql "host=db1.acme.internal dbname=app user=app_scram sslmode=verify-full sslrootcert=/etc/ssl/acme-root.crt"
psql "host=db.example.com dbname=app user=app sslrootcert=system"      # public CA; implies verify-full
```

- `sslrootcert=system` loads the TLS library's trusted roots and forces `verify-full` (a weaker mode is an error).
  It suits managed services with public CA certificates; with a private CA it fails with
  `certificate verify failed`. With OpenSSL, `SSL_CERT_FILE` and `SSL_CERT_DIR` change where "system" looks.
- Default file locations: `~/.postgresql/root.crt`, `postgresql.crt`, `postgresql.key`, `root.crl`; on Windows
  `%APPDATA%\postgresql\`. A client key readable by group or others is refused on Unix
  (`private key file ... has group or world access`).
- `sslnegotiation=direct` (17+) starts TLS at once, saving a round trip and letting TLS-aware proxies route by SNI;
  it requires `sslmode=require` or stronger and a PostgreSQL 17 or later server.
- `sslmode` is ignored on Unix sockets; when GSSAPI encryption is available it is used instead of TLS unless
  `gssencmode=disable`.
- Drivers that do not use libpq (JDBC, Go pgx, node-postgres, .NET) name and default these options differently;
  check `postgres-app-drivers` for each.

## Client certificate authentication

A client certificate can be the login itself (`cert` method) or a second factor next to a password
(`clientcert=verify-full`). With `cert`, the certificate's CN must equal the role name, or a `map=` in
`pg_hba.conf` translates it through `pg_ident.conf`; a regular expression maps a family of service certificates to
one role.

```text
# pg_ident.conf
# MAPNAME  SYSTEM-USERNAME                          PG-USERNAME
svc        app_api                                  app_api
svc        /^([a-z-]+)-worker\.acme\.internal$     app_api
```

Proven on 18.6: a certificate with CN `billing-worker.acme.internal` logged in as `app_api`, and `system_user`
showed `cert:CN=billing-worker.acme.internal`, so audit logs keep the real identity. With
`clientcert=verify-full`, a certificate whose CN does not match is refused with a generic `password authentication
failed` while the server log names the cause (`CN mismatch`); no certificate at all gives `connection requires a
valid client certificate`. Revoke certificates with `ssl_crl_file` or `ssl_crl_dir`, and keep client certificate
lifetimes short.

## SCRAM, channel binding and moving off md5

SCRAM-SHA-256 never sends the password and stores a salted, iterated verifier. Channel binding ties the SCRAM
exchange to the TLS session, so a proxy that terminates TLS with a different certificate cannot relay the login.

```bash
psql "host=db1.acme.internal dbname=app user=app_scram sslmode=verify-full sslrootcert=/etc/ssl/acme-root.crt channel_binding=require require_auth=scram-sha-256"
```

`require_auth=scram-sha-256` (16+) makes the client refuse a server that asks for anything weaker; against an md5
role it fails with `server requested a hashed password`.

md5 is deprecated in 18: setting an md5 password warns (`md5_password_warnings`, on by default). The documented
migration: make sure every client library supports SCRAM, keep `password_encryption = 'scram-sha-256'`, have every
md5 role set a new password (psql `\password` sends only the hash), then change `md5` to `scram-sha-256` in
`pg_hba.conf`. Until then, an `md5` line already uses SCRAM for any role whose stored password is SCRAM (checked: such a login
passed `require_auth=scram-sha-256 channel_binding=require`, while `system_user` still showed `md5:` from the rule). Raising
`scram_iterations` strengthens new verifiers against offline guessing and slows each login.

## Column encryption with pgcrypto and its limits

pgcrypto encrypts values inside the server, so the key travels to the server in SQL and lives in its memory during
the call. That protects against a stolen disk, backup or replica, not against a superuser, anyone who reads the
logs, or the server's memory. Proven on 18.6 with psql `\bind` supplying `$1` (key) and `$2` (HMAC key):

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE app.patients (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL,
                           ssn_enc bytea NOT NULL, ssn_hmac bytea NOT NULL);
INSERT INTO app.patients (name, ssn_enc, ssn_hmac)
VALUES ('Ada', pgp_sym_encrypt('123-45-6789', $1, 'cipher-algo=aes256, compress-algo=0, s2k-mode=3'),
        hmac('123-45-6789', $2, 'sha256'));
SELECT id FROM app.patients WHERE ssn_hmac = hmac('123-45-6789', $2, 'sha256');   -- equality lookup
SELECT pgp_sym_decrypt(ssn_enc, $1) FROM app.patients WHERE id = 1;
```

- Pass keys as bind parameters, never literals, and set `log_parameter_max_length = 0`: measured on 18.6, a
  slow-statement log line included `Parameters: $1 = '<the key>'` with the default -1, and literals appear in every
  logged statement.
- The 18.6 release fixed CVE-2026-14663: with OpenSSL 3 lacking the legacy provider, `cipher-algo=bf` (and cast5,
  3des, twofish) used to "encrypt" with a broken fallback; it now fails with `Cipher cannot be initialized`. Use
  `aes128`/`aes256`.
- For real separation of duties, encrypt in the application with keys from a KMS (envelope encryption) and store
  ciphertext; the database never sees the key. Key rotation, blind indexes and password hashing:
  [references/pgcrypto-column-encryption.md](references/pgcrypto-column-encryption.md).

## Encryption at rest: disks, cloud KMS and TDE

PostgreSQL core has no transparent data encryption (TDE) in 18; data files, WAL, temp files and logs are plain on
disk. Encrypt below the database:

| Where | Option |
|---|---|
| Linux | dm-crypt with LUKS on the data and WAL volumes, or an encrypted cloud volume |
| macOS | FileVault (APFS volume encryption) |
| Windows | BitLocker on the data volume |
| Cloud VMs and managed services | provider-encrypted volumes, snapshots and backups, with a customer-managed KMS key where the provider supports it |
| TDE in a fork | Percona's `pg_tde` (2.2.2) for Percona Server for PostgreSQL 17 and 18; encrypts tables, indexes and WAL, not temporary files or statistics yet |

These options were checked against documentation, not run here. Disk encryption protects a stolen disk or a
discarded volume, not a running, mounted system; the documentation
says the same. Encrypt backups and WAL archives separately (pgBackRest `repo1-cipher-type`, bucket encryption), and
keep their keys outside the backup.

## Worked example: "the auditor wants proof that every connection is encrypted"

1. Show the rules: `pg_hba_file_rules` has only `hostssl` lines for TCP and a final `host ... reject`, and no
   `error` rows.
2. Show live sessions: every row of `pg_stat_ssl` joined to `pg_stat_activity` with a `client_addr` has
   `ssl = t` and `version = TLSv1.3`.
3. Show history: with `log_connections` including `authorization`, each login line ends in `SSL enabled
   (protocol=TLSv1.3, cipher=TLS_AES_256_GCM_SHA384, bits=256)`.
4. Show clients verify the server: connection strings or service files use `sslmode=verify-full`; a test with a
   wrong host name fails with `server certificate for "db1.acme.internal" ... does not match host name`.
5. Show authentication strength: no rows from the md5 query, and `scram-sha-256` or `cert` on every rule.

## Verify TLS from the client side

Prove encryption from a client, because a server with `ssl = on` still accepts plain connections unless `pg_hba.conf`
refuses them.

```bash
psql "host=db1.acme.internal dbname=app user=app_scram sslmode=verify-full sslrootcert=ca.crt" -Atc 'SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid()'   # t|TLSv1.3
psql "host=db1.acme.internal dbname=app user=app_scram sslmode=disable" -c 'SELECT 1'           # expect: no encryption, refused
psql "host=10.0.0.5 dbname=app user=app_scram sslmode=verify-full sslrootcert=ca.crt" -c 'SELECT 1'   # expect: does not match host name, unless the IP is in the certificate
openssl x509 -in server.crt -noout -enddate -ext subjectAltName
```

Each refusal proves one rule: plain connections are rejected, and a client talking to the wrong name stops.

## Gotchas

These are the encryption failures seen most often, each with its cause and fix.

1. **Clients connect in plain text although `ssl = on`.** libpq's default `prefer` falls back, and a `host` line
   accepts both. Add the `hostnossl`/`host ... reject` line and set clients to `verify-full`.
2. **`certificate verify failed` with `sslrootcert=system`.** The server uses a private CA. Point `sslrootcert` at
   the CA file instead.
3. **`server certificate for "x" ... does not match host name "y"`.** The name the client uses is not in the
   certificate's subjectAltName. Reissue the certificate with every DNS name and IP clients use.
4. **`password authentication failed` for a correct password.** With `clientcert=verify-full`, a CN mismatch is
   reported this way; read the server log.
5. **`weak sslmode "prefer" may not be used with sslnegotiation=direct`.** Direct TLS needs `require` or stronger.
6. **`SSL error: tlsv1 alert protocol version`.** Client and server have no TLS version in common, for example a
   TLS 1.2 client against `ssl_min_protocol_version = 'TLSv1.3'`.
7. **The server will not start after enabling TLS.** Key permissions or ownership are too open, or the key needs a
   passphrase. Fix with `chmod 0600` and ownership by the server's OS user.
8. **pgcrypto decrypt fails after the 18.6 update.** Data was encrypted with a legacy cipher that OpenSSL never ran;
   `ignore-cipher-failure=1` exists only to recover and re-encrypt such values.

## Checklist

Check these points before you call encryption done.

- [ ] `ssl = on`, TLS 1.2 minimum (1.3 where all clients allow), certificates with every client-facing name.
- [ ] `pg_hba.conf` has `hostssl` rules only for TCP and a final reject; `pg_hba_file_rules` shows no errors.
- [ ] Clients use `sslmode=verify-full` with the right root (`system` only for public CAs).
- [ ] No md5 hashes left; `channel_binding=require` or `require_auth` where drivers support them.
- [ ] Certificate expiry is monitored, and rotation by reload has been rehearsed.
- [ ] Data, WAL and backup volumes are encrypted, with keys held outside the database host.
- [ ] pgcrypto keys never appear as literals, and `log_parameter_max_length = 0`.

## Anti-patterns in PostgreSQL encryption

| Do not | Do this instead |
|---|---|
| stop at `sslmode=require` | `verify-full`, which also checks who you reached |
| leave `host` rules open after adding `hostssl` | a final `host ... reject` |
| keep md5 passwords | SCRAM, after every client supports it |
| write pgcrypto keys as literals | bind parameters, and `log_parameter_max_length = 0` |
| call disk encryption protection from a running attacker | column or application encryption for those threats |
| keep backup keys beside the backup | a key store outside it |

## See also

- `postgres-security-roles`: roles, `pg_hba.conf` and row-level security.
- `postgres-backup-restore`: backup encryption.
- `postgres-auditing-compliance`: proving controls to an auditor.
- `postgres-app-drivers`: TLS options per driver.
- `postgres-libpq-protocol`: `sslmode`, service files and `require_auth`.

## Sources

- https://www.postgresql.org/docs/18/ssl-tcp.html
- https://www.postgresql.org/docs/18/runtime-config-connection.html
- https://www.postgresql.org/docs/18/libpq-ssl.html, libpq-connect.html
- https://www.postgresql.org/docs/18/auth-cert.html, auth-password.html, auth-username-maps.html
- https://www.postgresql.org/docs/18/pgcrypto.html
- https://www.postgresql.org/docs/18/encryption-options.html
- https://www.postgresql.org/docs/18/release-18.html, https://www.postgresql.org/docs/release/18.6/
- https://github.com/percona/pg_tde (2.2.2)
