---
name: postgres-local-cluster
description: 'Runs one private PostgreSQL cluster per desktop app, tool or project on the user''s own machine: a pinned runtime, initdb with the builtin locale and checksums, a socket-only server, scram and peer authentication, owner and app roles, adopting a server a crashed app left running, clients immune to PG* variables and .pgpass, WAL archive, base backups, point-in-time restore, restore drills, upgrades and bundling the binaries in an app. Use for embedded or bundled Postgres in a desktop app, or a database per project.'
metadata:
  tags:
  - postgres
  - local-cluster
  - embedded
  - desktop
  - initdb
  - backup
  - pitr
  - pg_upgrade
  - bundling
---

# PostgreSQL local cluster per app

Run one private PostgreSQL cluster per app or project, the way a DBA runs a fleet: the runtime is pinned so it never
changes under the data, the server listens only on a Unix socket, roles have least privilege, and a weekly drill
proves the backups restore. Backups: [references/backup-restore.md](references/backup-restore.md). Upgrades,
bundling and Windows: [references/upgrade-ship-windows.md](references/upgrade-ship-windows.md). Vector and text
search tables: `postgres-vector-search`.

## Step 0: read what is installed

Versions change under you, so read them from the runtime and the data folder before any step.

```bash
B=<runtime>/bin; R=<root>                               # Workflow 1 picks the runtime
"$B/postgres" --version; cat "$R/data/PG_VERSION"         # majors must match
"$B/pg_controldata" -D "$R/data" | grep -E 'checksum version|cluster state'
ls "$("$B/pg_config" --pkglibdir)" | grep -E '^(vector|pg_trgm|basic_archive)\.'
"$B/psql" -X -h "<socket_dir>" -p <port> -d acme -Atc "SELECT extname, extversion FROM pg_extension"
```

Release facts come from https://www.postgresql.org/support/versioning/, the notes of every minor you skip, and
pgvector's CHANGELOG.

## Layout and a runtime pin file

A fixed layout keeps every path predictable; a small pin file (here `pg.toml`) records the runtime and the cluster.

```
<root>/                      the cluster root, e.g. under the app's data folder (always quote it: may contain spaces)
  data/                      PGDATA, mode 0700
  archive/                   WAL segments and .history files (basic_archive target)
  backups/<ts>-full/ <ts>-incr/   pg_basebackup outputs, each with backup_manifest
  dumps/  logs/  drills.jsonl
<secrets>/db.json            role passwords, 0600; db.pgpass for libpq clients, 0600
<socket_dir>/                short, no spaces, 0700, e.g. <home>/.acme/run
```

```toml
[runtime]
major = 18                                  # must equal data/PG_VERSION
bundled = "pg/{platform}-{arch}"            # inside the app bundle; packaged builds use only this
dev = "/Applications/Postgres.app/Contents/Versions/{major}"   # macOS dev runs only; never "latest"

[cluster]
name = "acme"                               # database acme, roles acme_owner and acme_app
root = "{dataDir}/pg"
socket_dir = "{home}/.acme/run"
port = 5432                                 # part of the socket file name; on Windows a TCP port per cluster

[backup]
incremental_above_gb = 10
keep_chains = 4
mirrors = []                                # a second disk, then off-site
```

## Workflow 1: resolve the runtime

The runtime must be the exact major the data was created with, from a location no package manager touches.

1. Packaged app: the bundled runtime only. Development: the bundle if present, else Postgres.app `Versions/<major>`
   on macOS or a PGDG package path on Linux. Never `PATH`, Homebrew or `Versions/latest`: `brew upgrade` or an app
   update swaps binaries under the data.
2. Refuse to start, naming both values, when `postgres --version` major differs from the pin file or from
   `data/PG_VERSION`; when `pkglibdir` lacks a required extension (`vector`, `pg_trgm`, `basic_archive`); or when
   the runtime's pgvector `default_version` is older than the database's `extversion`.
3. Check the socket path length before initdb and every start: `<socket_dir>/.s.PGSQL.<port>` must be at most 103
   bytes on macOS and 107 on Linux (bytes, not characters).

Verify: `Buffer.byteLength(path.join(socketDir, '.s.PGSQL.' + port)) <= (process.platform === 'darwin' ? 103 : 107)`
and every Step 0 check passes.

## Workflow 2: create the cluster (macOS, Linux)

initdb with fixed locale flags makes the cluster independent of the user's environment.

```bash
B=<runtime>/bin R=<root> S=<socket_dir> P=5432 N=acme
umask 077 && mkdir -p "$R"/{archive,backups,dumps,logs} "$S"
"$B/initdb" -D "$R/data" -E UTF8 --locale=C --locale-provider=builtin --builtin-locale=PG_UNICODE_FAST \
  --auth-local=peer --auth-host=reject       # PG 17: --builtin-locale=C.UTF-8; checksums are on by default from 18
echo "include 'app.conf'" >> "$R/data/postgresql.conf"
```

- `--locale=C`, because initdb otherwise reads `LANG`/`LC_*`: a missing locale fails initdb, a present one makes the
  cluster machine-specific.
- Builtin locale, not ICU, as the default: ICU ties every text index to the ICU library version. Put an ICU collation
  only on columns that need language order (`title text COLLATE "und-x-icu"`).
- Pass `--auth-host=reject` with `--auth-local`: alone, initdb writes `trust` for host lines.

The app owns `data/app.conf` and rewrites it whole; never edit `postgresql.auto.conf` by hand.

```ini
listen_addresses = ''
port = 5432
unix_socket_directories = '<socket_dir>'
unix_socket_permissions = 0700
password_encryption = scram-sha-256
wal_sync_method = fsync_writethrough        # macOS: plain fsync() leaves data in the drive cache
archive_mode = on
archive_library = 'basic_archive'
basic_archive.archive_directory = '<root>/archive'
archive_timeout = '5min'
summarize_wal = on                          # incremental backups need it from before the chain's full backup
wal_summary_keep_time = '30d'               # a laptop closed for two weeks must not break the chain
```

`data/pg_hba.conf` is replaced whole. The first match wins and `all` does not match replication, so
`pg_basebackup` needs its own line:

```
local  acme         acme_owner,acme_app  scram-sha-256
local  all          <os_user>            peer
local  replication  <os_user>            peer
```

Start the server (Workflow 3), then create roles and extensions as the OS user over peer. The SQL goes through
stdin so passwords never appear in `ps`:

```bash
OWNER_PW=$(jq -r .owner "<secrets>/db.json") APP_PW=$(jq -r .app "<secrets>/db.json")
"$B/psql" -X -v ON_ERROR_STOP=1 -h "$S" -p "$P" -d postgres <<SQL
CREATE ROLE ${N}_owner LOGIN PASSWORD '$OWNER_PW';
CREATE ROLE ${N}_app LOGIN PASSWORD '$APP_PW';
CREATE DATABASE $N OWNER ${N}_owner;
REVOKE ALL ON DATABASE $N FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE $N TO ${N}_app;
\c $N
CREATE EXTENSION vector;                    -- not a trusted extension: superuser only
CREATE EXTENSION pg_trgm;
ALTER DEFAULT PRIVILEGES FOR ROLE ${N}_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${N}_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${N}_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${N}_app;
SQL
```

Migrations run as `<name>_owner`: since PG 15 only the database owner may create in `public`, and the app role gets
DML through the default privileges.

Verify (read back, compare every value):

```sql
SELECT current_setting('data_checksums'), current_setting('listen_addresses'), current_setting('unix_socket_permissions');  -- on | '' | 0700
SELECT datlocprovider::text, datlocale, datacl FROM pg_database WHERE datname = 'acme';   -- b | PG_UNICODE_FAST | owner + app only
SELECT extname, extversion FROM pg_extension;                                             -- vector, pg_trgm
SELECT line_number, type, database, user_name, auth_method, error FROM pg_hba_file_rules; -- 3 lines, error null
```

Also check that `ls -l "$S"` shows the socket as `srwx------`, and that `CREATE TABLE t()` as `acme_app` fails with
"permission denied for schema public".

## Workflow 3: start, stop, adopt a running server

`pg_ctl start` detaches the postmaster into its own session, so it outlives a crashed app. The next start must adopt
it, not start a second server. This TypeScript runs in the process that manages the cluster; the same logic ports to
any language.

```ts
import { execFile } from 'node:child_process';
import { readdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
const run = promisify(execFile);

export interface Cluster { bin: string; root: string; socketDir: string; port: number }
const pgEnv = () => ({ HOME: process.env.HOME ?? '', USER: process.env.USER ?? '', LC_ALL: 'C' });   // no PG*, no DYLD_*

async function answers(c: Cluster): Promise<boolean> {
  return run(path.join(c.bin, 'pg_isready'), ['-q', '-h', c.socketDir, '-p', String(c.port), '-t', '2'], { env: pgEnv() })
    .then(() => true, () => false);
}

export async function startCluster(c: Cluster): Promise<void> {
  const data = path.join(c.root, 'data');
  if (await answers(c)) return;                                       // adopt what a crashed app left running
  const pidFile = path.join(data, 'postmaster.pid');
  const pid = Number((await readFile(pidFile, 'utf8').catch(() => '')).split('\n')[0]);
  if (pid > 0) {
    const comm = await run('ps', ['-p', String(pid), '-o', 'comm='], { env: pgEnv() }).then((r) => r.stdout.trim(), () => '');
    if (comm.endsWith('postgres')) throw new Error(`postgres ${pid} owns ${data} but does not answer; check ${c.root}/logs`);
    await rm(pidFile);                                                // stale: the PID now belongs to another program
  }
  const archive = path.join(c.root, 'archive');
  for (const f of await readdir(archive)) if (f.startsWith('archtemp.')) await rm(path.join(archive, f));   // left by a crash
  await run(path.join(c.bin, 'pg_ctl'), ['start', '-D', data, '-l', path.join(c.root, 'logs', 'postgres.log'), '-w', '-t', '60'], { env: pgEnv() });
}

export async function stopCluster(c: Cluster): Promise<void> {
  await run(path.join(c.bin, 'pg_ctl'), ['stop', '-D', path.join(c.root, 'data'), '-m', 'fast', '-w', '-t', '60'], { env: pgEnv() });
}
```

- Never delete `postmaster.pid` or `.s.PGSQL.<port>.lock` while a postgres for that folder runs.
- Stop the cluster last when the app quits, after every worker that holds a connection.

Verify: kill the app with `kill -9`, start it again, and `pg_ctl status -D data` prints one PID, the same as before.

## Workflow 4: connect so nothing in the environment can redirect you

Explicit host, port, dbname and user are not enough. `PGOPTIONS` can make every session read-only, `PGSSLMODE`,
`PGREQUIREAUTH` or `PGTARGETSESSIONATTRS` can refuse the connection, and `PGTZ`, `PGDATESTYLE` and `PGGEQO` change
settings no conninfo field overrides. node-postgres also falls back to `PG*` for falsy values (`options: ''`,
`port: 0`). With scram roles, a missing password sends libpq, node-postgres and asyncpg to `~/.pgpass`, where a
`*:*:*:*:` line answers for any server.

```ts
// first lines of the process, before anything imports 'pg'
for (const k of Object.keys(process.env)) if (k.startsWith('PG')) delete process.env[k];
const { default: pg } = await import('pg');
const secrets = JSON.parse(await readFile(secretsFile, 'utf8')) as { app: string };
export const pool = new pg.Pool({
  host: cluster.socketDir, port: cluster.port, database: 'acme', user: 'acme_app',
  password: secrets.app, ssl: false, application_name: 'acme', max: 8,
});
```

```python
# Python worker: scrub, then name every field; passfile keeps the password out of env and argv
import os
for k in [k for k in os.environ if k.startswith("PG")]:
    del os.environ[k]
from psycopg.conninfo import make_conninfo
dsn = make_conninfo(host=db["host"], port=db["port"], dbname=db["dbname"], user=db["user"],
                    passfile=db["passfile"], sslmode="disable", application_name="acme-worker")
# asyncpg: asyncpg.connect(host=..., port=..., database=..., user=..., password=..., ssl=False)
```

Pass workers `{host, port, dbname, user, passfile}`; `db.pgpass` holds one exact line
`<socket_dir>:<port>:<db>:<user>:<password>` at 0600.

Verify: run each client with `PGOPTIONS='-c default_transaction_read_only=on' PGSSLMODE=require PGTZ=Asia/Tokyo PGPORT=1`
in its environment and a `*:*:*:*:wrong` line in `~/.pgpass`; an `INSERT` succeeds and `SHOW TimeZone` prints the
server default.

## Workflow 5: back up

A local cluster backs itself up in layers, all on the user's machine plus mirrors.

| Layer | What | When |
|---|---|---|
| WAL archive | `basic_archive` into `<root>/archive` (temp file, fsync, durable rename) | continuous; `archive_timeout` bounds the gap |
| Base backup | `pg_basebackup` full; incremental chain only above `incremental_above_gb` | nightly |
| Dump | `pg_dump -Fc` + `pg_dumpall --globals-only` | nightly: survives a major-version change, restores one table |
| Verify | `pg_verifybackup -q` on every base backup | after each backup |
| Mirror | copy finished files (never `archtemp.*`) to each mirror: copy, fsync, rename, compare hash | after each verify |
| Retention | delete whole chains, oldest first, then `pg_archivecleanup` up to the oldest kept full | after each full |

`archive_command` and `archive_library` exclude each other; setting both stops the archiver. Health check after every
backup and at app start: `SELECT archived_count, failed_count, last_failed_wal FROM pg_stat_archiver` plus the count
of `data/pg_wal/archive_status/*.ready`; a growing `.ready` count means one segment is blocked.

Run backups from the app's scheduler while it runs, and at start catch up a run missed while it was closed (a stopped
cluster does not change). Commands and failure messages: [references/backup-restore.md](references/backup-restore.md).

Verify: `pg_verifybackup -q` exits 0 for the newest backup, `failed_count` is unchanged, and the newest archive
file is younger than `archive_timeout` plus one minute.

## Workflow 6: restore and drill

Every restore starts by moving `data/` aside (`mv data data.before-restore-<ts>`), never by deleting it.
Point-in-time restores set `recovery_target_time` (with a time zone), `recovery_target_action = 'promote'` and
`recovery.signal`, from the newest backup that ended before the target. One table comes from the nightly dump
(`pg_restore -t`). The weekly drill restores the latest chain into a scratch folder on its own port and socket with
`archive_mode = off`, runs the checks, deletes the folder and appends PASS or FAIL with timings to `drills.jsonl`.
Procedures: [references/backup-restore.md](references/backup-restore.md).

Verify: `drills.jsonl` has a PASS younger than 8 days; the app shows a warning when it does not.

## Workflow 7: upgrade

Minor upgrades swap binaries; major upgrades run `pg_upgrade`.

- Minor: stop, swap the runtime, start, then apply the "Migration to Version X.Y" items of every skipped minor. After
  moving to 18.6 or 17.11, take a new full backup and start a new chain: earlier minors could miss visibility-map
  changes in WAL summaries and write incorrect incremental backups.
- pgvector: `ALTER EXTENSION vector UPDATE` in each database after the runtime carries the new version.
- Major: verified backup, then `initdb` the new cluster with the same locale flags (`--no-data-checksums` when the
  old one has none), `pg_upgrade --check`, run with `--clone` on APFS (else `--copy`), analyze, update extensions,
  new full backup. Always pass `-s <socket_dir>`. Steps and failures:
  [references/upgrade-ship-windows.md](references/upgrade-ship-windows.md).

## Workflow 8: ship the engine inside an app

An app that runs its own cluster ships the PostgreSQL binaries with it.

- Bundle every binary the workflows above run, plus `lib/` and `share/`, as plain files outside any archive format
  the OS cannot execute from (for Electron: `extraResources`, never inside `asar`).
- Postgres.app binaries are for development only: their libraries have absolute install names under
  `/Applications/Postgres.app`. Ship a relocatable build (`--disable-rpath`, `@loader_path` install names) and sign
  every Mach-O after the last rewrite.
- Windows has no peer authentication: the cluster listens on `127.0.0.1` with its own port and scram on every line.
  Nothing in that section has run on Windows here; gate releases on a Windows CI drill.

Verify: move the packaged app to another folder, start it on a machine without Postgres.app, and the Workflow 2
read-back and a drill pass; `otool -L` on every bundled Mach-O lists only `@loader_path`, `@rpath`, `/usr/lib` and
`/System` paths.

## Worked example: "the app shows a blank screen after the laptop crashed"

The app's log says `pg_ctl: another server might be running; trying to start server anyway` and then a timeout.
Walk Workflow 3 by hand:

1. `pg_isready -h <socket_dir> -p 5432`: no response, so no server is answering.
2. `head -1 data/postmaster.pid` gives 812; `ps -p 812 -o comm=` prints `Safari`: after the reboot the PID belongs
   to another program, so the PID file is stale.
3. Remove only that file, delete any `archtemp.*` in `archive/`, then `pg_ctl start -D data -l logs/postgres.log -w`.
4. The log shows `database system was interrupted; last known up at ...` and `redo done`: crash recovery replayed
   the WAL, and committed data is intact (with `wal_sync_method = fsync_writethrough`).
5. Run the backup health check (`pg_stat_archiver`) and take a new base backup if the last one is older than a day.

If `ps` had printed `postgres`, the server was alive but stuck: read `logs/postgres.log` before touching any file.

## Checklist

Check these points before you call a local app cluster done.

- [ ] Runtime resolved from the bundle or a pinned dev path; majors match the data.
- [ ] Socket path within the byte limit; socket dir 0700; `listen_addresses = ''`.
- [ ] initdb with `--locale=C`, builtin provider, checksums; `--auth-host=reject`.
- [ ] `pg_hba.conf` has the app line, peer for the OS user, and a replication line.
- [ ] Owner and app roles; migrations as owner; extensions created by the superuser.
- [ ] Clients scrub `PG*` and pass every field and a password or passfile.
- [ ] WAL archive healthy; nightly backups verified; weekly drill passes.
- [ ] Upgrades keep a verified backup and the old data until a drill passes on the new one.

## Gotchas

These are the failures seen most often with a local app cluster, each with its cause and fix.

1. **pg_basebackup is refused.** `no pg_hba.conf entry for replication connection`: `all` does not match
   replication. Add `local replication <os_user> peer`.
2. **A client lands in a read-only session, another time zone or another server.** `PGOPTIONS`, `PGTZ`, `PGPORT`
   filled what the conninfo left open. Delete `PG*` in the process before the driver loads (Workflow 4).
3. **A wrong password still connects.** The driver asked `~/.pgpass` and a `*` line answered. Always pass the
   password or an app-owned passfile.
4. **initdb fails on another machine.** "invalid locale settings; check LANG and LC_* environment variables". Use
   `--locale=C` plus the builtin provider flags.
5. **Every text index is flagged after a runtime update.** Collation version mismatch from an ICU default. Use the
   builtin default; on mismatch `REINDEX` then `ALTER DATABASE ... REFRESH COLLATION VERSION`.
6. **The server starts without a socket.** "Unix-domain socket path ... is too long (maximum 103 bytes)". Use a
   short, space-free socket dir, checked before every start.
7. **Archiving silently stops.** A different file with the same name sits in the archive, or both `archive_command`
   and `archive_library` are set. Compare the files; never delete the archive copy blindly.
8. **Committed data lost on power loss (macOS).** `fsync()` does not flush the drive cache. Set
   `wal_sync_method = fsync_writethrough`.
9. **Incremental backup fails** with "WAL summaries are required" or "cannot be taken unless WAL summarization is
   enabled". Take a full backup and start a new chain.
10. **The app starts a second server or refuses to start.** "lock file ... already exists". Adopt a server that
    answers; remove the PID file only when its PID is not a postgres (Workflow 3).
11. **`CREATE EXTENSION vector` or `CREATE TABLE` is denied.** `vector` is not trusted; only the owner creates in
    `public`. Create extensions at setup as the OS superuser, run migrations as the owner.
12. **The bundled server crashes after Postgres.app updates.** dyld "Library not loaded: /Applications/Postgres.app/...".
    Ship a relocatable build.

## Anti-patterns for a private cluster

Each of these turns a private database into a shared one, or a recoverable one into a lost one.

| Do not | Do instead |
|---|---|
| Resolve the runtime from `PATH`, Homebrew or `Versions/latest` | Pin the bundle or a versioned path, and refuse a major that differs from the data |
| Listen on TCP on macOS or Linux | Set `listen_addresses = ''` and use a 0700 socket directory |
| Let the app connect as the superuser or owner | Use the app role for DML and the owner for migrations |
| Delete `data/` before a restore | Move it aside first and delete it only after a drill passes |
| Remove `postmaster.pid` because the server looks stuck | Check the PID with `ps` first; remove it only when it is not a postgres |
| Ship Postgres.app binaries inside the app | Ship a relocatable build and sign every Mach-O |

## See also

Related skills in this library, each one works on its own:

- `postgres-install`: installing a server for everyone on a machine.
- `postgres-backup-restore`: backup strategy for servers.
- `postgres-vector-search`: vector and text search tables.
- `postgres-libpq-protocol`: the rules behind connections immune to `PG*`.
- `postgres-python`: Python clients for a private cluster.
- `postgres-zero-downtime-upgrades`: major upgrades on a server with users.
