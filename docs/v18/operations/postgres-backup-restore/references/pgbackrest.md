---
title: pgBackRest setup and commands
author: MOZGII, Inc.
lang: en
---

# pgBackRest setup and commands

This reference sets up pgBackRest (2.60 at the time of writing; read `pgbackrest version`) for one PostgreSQL server
with a repository on local disk or object storage, then lists the daily commands.

## Contents

The sections of this reference on pgBackRest setup and commands:

1. pgBackRest configuration file
2. PostgreSQL settings for pgBackRest archiving
3. Creating the stanza and checking it
4. Taking backups: full, differential and incremental
5. Restoring with pgBackRest
6. Monitoring pgBackRest
7. pgBackRest gotchas

## pgBackRest configuration file

pgBackRest reads `/etc/pgbackrest/pgbackrest.conf`. A stanza names one PostgreSQL cluster; `repo1` is where backups go.

```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<long random passphrase from your secret store>
repo1-bundle=y
repo1-block=y
compress-type=zst
process-max=4
start-fast=y
archive-async=y
spool-path=/var/spool/pgbackrest
log-level-console=info

[main]
pg1-path=/var/lib/postgresql/18/main
```

`repo1-retention-full=2` keeps two full backups and everything they need. `repo1-bundle` packs small files and is
required by `repo1-block`, which turns on block-level incremental backups. `start-fast` asks for an immediate
checkpoint at backup start.

Put a comment on its own line, starting with `#`. pgBackRest takes all the text after `=` as the value, so
`repo1-bundle=y   # pack small files` stops the backup with `boolean option 'repo1-bundle' must be 'y' or 'n'`
(pgBackRest 2.60.0). `stanza-create` does not read that option, so it succeeds and hides the mistake until the first
backup.

Object storage instead of a local path:

```ini
repo1-type=s3
repo1-s3-bucket=acme-pg-backups
repo1-s3-endpoint=s3.eu-central-1.amazonaws.com
repo1-s3-region=eu-central-1
repo1-s3-key-type=auto
repo1-path=/main
```

`repo1-s3-key-type=auto` uses the instance's IAM role, so no keys sit in the file.

Keep the file readable only by the `postgres` OS user (0640, group `postgres`), because it holds the cipher passphrase.

## PostgreSQL settings for pgBackRest archiving

pgBackRest receives WAL through `archive_command`.

```ini
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
wal_level = replica
max_wal_senders = 3
```

Restart PostgreSQL after changing `archive_mode`.

## Creating the stanza and checking it

`stanza-create` initializes the repository for the cluster; `check` proves WAL archiving reaches it.

```bash
sudo -u postgres pgbackrest --stanza=main stanza-create
sudo -u postgres pgbackrest --stanza=main check
```

## Taking backups: full, differential and incremental

A full backup copies everything; a differential copies changes since the last full; an incremental copies changes
since the last backup of any type.

```bash
sudo -u postgres pgbackrest --stanza=main --type=full backup
sudo -u postgres pgbackrest --stanza=main --type=diff backup
sudo -u postgres pgbackrest --stanza=main --type=incr backup
sudo -u postgres pgbackrest --stanza=main info          # list backups, sizes and WAL range
```

A common schedule: weekly full, daily differential, hourly incremental, from cron or a systemd timer as `postgres`.

## Restoring with pgBackRest

Restore needs the server stopped. `--delta` reuses files that did not change, which makes restores of large
clusters much faster.

```bash
sudo systemctl stop postgresql
sudo -u postgres pgbackrest --stanza=main --delta restore                       # latest state
sudo -u postgres pgbackrest --stanza=main --delta --type=time \
  --target="2026-11-28 09:41:00+00" --target-action=promote restore             # point in time
sudo systemctl start postgresql
```

- `--set=<backup label>` restores a specific backup from `info`.
- `--db-include=app` restores only one database (others become unusable stubs): for recovering one database into a
  scratch server.
- Restore into a different directory for a drill with `--pg1-path=/scratch/pgdata`, then start it on another port
  with `archive_mode = off`.

## Monitoring pgBackRest

Check backup age and archive health from monitoring, not by hand.

```bash
sudo -u postgres pgbackrest --stanza=main --output=json info | jq '.[0].backup[-1].timestamp.stop'
```

Alert when the newest backup is older than the schedule allows, when `pg_stat_archiver.failed_count` grows, or when
`check` fails.

## pgBackRest gotchas

These pgBackRest problems come up most often, each with its cause and fix.

1. **`archive-push` times out and WAL piles up.** Enable `archive-async` with a `spool-path`, and check repository
   reachability.
2. **Backups from a standby.** Set `backup-standby=y` with both `pg1-*` (primary) and `pg2-*` (standby) hosts; the
   primary still must be reachable.
3. **Lost cipher passphrase.** Encrypted backups cannot be read. Store it in a secret manager with its own backup.
4. **Retention deleted WAL a backup needed.** Retention follows full backups; keep `repo1-retention-full` at 2 or
   more, and never delete repository files by hand.
