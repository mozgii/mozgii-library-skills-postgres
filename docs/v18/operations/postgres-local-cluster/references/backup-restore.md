---
title: Local cluster backup and restore
author: MOZGII, Inc.
lang: en
---

# Local cluster backup and restore

This reference holds the exact backup and restore commands for an app's private PostgreSQL cluster. Commands assume
`B=<runtime>/bin R=<root> S=<socket_dir> P=<port> ME=<os user>` and run as the OS user over peer. Run each step as a
job in the app's scheduler, one backup job at a time, resumable where noted.

## Contents

The sections of this reference on local cluster backup and restore:

1. WAL archive and its health check
2. Base backups: full and incremental chain
3. Combine and verify
4. Dumps and mirrors
5. Retention and scheduling
6. Restore to the latest state
7. Point in time; one table
8. Weekly drill

## 1. WAL archive and its health check

`basic_archive` copies each completed WAL segment to `archtemp.<file>.<pid>.<ms>` in the archive folder, fsyncs it,
renames it and fsyncs the folder. If the destination exists with identical bytes, it reports success; if the bytes
differ, it raises an ERROR, the segment stays `.ready`, and every later segment waits behind it while the server
keeps running.

```sql
SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;
```

```bash
ls "$R/data/pg_wal/archive_status/" | grep -c '\.ready$'     # > 2 for longer than archive_timeout: alert
ls -t "$R/archive" | grep -v '^archtemp\.' | head -1           # newest archived file
```

When `failed_count` grows: read `last_failed_wal` and compare `cmp "$R/data/pg_wal/$F" "$R/archive/$F"`. Identical
bytes never fail, so a difference means the archive holds a segment from another cluster or timeline. Move that file
aside, never delete it; archiving resumes within about a minute.

## 2. Base backups: full and incremental chain

`pg_basebackup` takes a full copy; with `--incremental` it copies only blocks changed since a previous backup.

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
"$B/pg_basebackup" -h "$S" -p "$P" -U "$ME" -D "$R/backups/$TS-full" -c fast -X stream --no-password
# incremental, only when the cluster is above incremental_above_gb:
"$B/pg_basebackup" -h "$S" -p "$P" -U "$ME" -D "$R/backups/$TS-incr" -c fast -X stream --no-password \
  --incremental="$R/backups/<previous backup>/backup_manifest"
```

- Choose by size: on a small cluster an incremental is still about half a full (mostly streamed WAL), and every link
  adds a failure point.
- `summarize_wal = on` must be active before the chain's full backup. pg_basebackup removes its target on failure.
- On "summaries ... are incomplete" or "cannot be taken unless WAL summarization is enabled": take a full backup and
  start a new chain. Do not retry the incremental.
- After moving to 18.6 or 17.11 or later, start a new chain with a full backup: earlier minors could miss
  visibility-map changes in WAL summaries.
- Record each backup's parent in a `chain.json` beside it, so retention and restore never infer the chain from
  timestamps.

## 3. Combine and verify

`pg_combinebackup` rebuilds a full data directory from a full backup and its incrementals; `pg_verifybackup` checks
a backup against its manifest.

```bash
"$B/pg_verifybackup" -q "$R/backups/$TS-full"                     # every backup, right after it is taken
"$B/pg_combinebackup" -n -o "$OUT" "$R/backups/<full>" "$R/backups/<incr1>" "$R/backups/<incr2>"       # dry run
"$B/pg_combinebackup" --clone -o "$OUT" "$R/backups/<full>" "$R/backups/<incr1>" "$R/backups/<incr2>"  # APFS; Linux: --copy-file-range
"$B/pg_verifybackup" -q "$OUT"
```

- List backups oldest to newest. A wrong order fails with "is a full backup, but only the first backup should be a
  full backup"; a missing link with "starts at LSN ..., but expected ...".
- pg_combinebackup checks the chain, not each backup's integrity: verify inputs and output.
- `-k/--link` makes the output share files with the inputs; use it only for a throwaway restore.

## 4. Dumps and mirrors

Logical dumps complement the physical chain: they survive a major-version change and restore one table.

```bash
"$B/pg_dump" -h "$S" -p "$P" -d acme -Fc -f "$R/dumps/$TS.dump"
"$B/pg_dumpall" -h "$S" -p "$P" --globals-only -f "$R/dumps/$TS-globals.sql"
```

- PG 18 does not dump statistics by default (`--statistics` adds them); run `ANALYZE` after a restore.
- Mirrors: after a backup or dump verifies, copy it to each mirror. Write `<name>.part`, fsync, rename, then compare
  size and SHA-256 with the source. Copy archive files in name order, skip `archtemp.*`, never overwrite a different
  file of the same name. The job is resumable by file.
- A mirror on the same disk is not a backup: the first mirror is another disk, the second off-site.

## 5. Retention and scheduling

Retention deletes whole chains; scheduling runs the jobs while the app is open and catches up at start.

- Keep `keep_chains` whole chains. Delete the oldest chain first, never a link inside a kept chain: deleting a full or
  intermediate backup orphans every later incremental.
- Then trim the archive to the oldest kept full: `"$B/pg_archivecleanup" "$R/archive" <the .backup file name for that
  full's start segment>`; the name is in the full's `backup_label` (`START WAL LOCATION ... (file ...)`).
- Keep dumps for the same window as chains.
- Schedule: nightly base backup and dump, verify after each, mirror after each verify, weekly drill. At app start,
  compare last success times with the schedule and enqueue what was missed.
- With the app closed: macOS launchd `StartCalendarInterval` runs a job missed during sleep at wake (several missed
  runs coalesce into one) but not one missed while the Mac was off; Windows Task Scheduler
  `New-ScheduledTaskSettingsSet -StartWhenAvailable`. Use these only for off-site sync and drills.

## 6. Restore to the latest state

A restore to the latest state replays the whole archive after the newest backup.

```bash
"$B/pg_ctl" stop -D "$R/data" -m fast -w || true
mv "$R/data" "$R/data.before-restore-$TS"
"$B/pg_combinebackup" --clone -o "$R/data" <chain, oldest first>   # or cp -Rp a full backup
chmod 700 "$R/data"
cat >> "$R/data/app.conf" <<EOF
restore_command = 'cp "$R/archive/%f" "%p"'
EOF
touch "$R/data/recovery.signal"
"$B/pg_ctl" start -D "$R/data" -l "$R/logs/postgres.log" -w -t 300
```

- `restore_command` must return non-zero for a missing file (`cp` does); the server also asks it for `.history`
  files.
- Recovery replays to the end of the archive and promotes. Check `SELECT pg_is_in_recovery()` is `f` and
  `recovery.signal` is gone, then remove the `restore_command` line, reload, and take a new full backup: the cluster is
  on a new timeline.
- Before promoting, delete `archtemp.*` and check the archive holds no clashing segment from another machine.

## 7. Point in time; one table

A point-in-time restore is the same as section 6 with the chain chosen by time and three more lines.

```ini
recovery_target_time = '2026-03-14 09:20:00+01'   # always with a zone
recovery_target_action = 'promote'                  # the default is pause; shutdown keeps recovery.signal
recovery_target_inclusive = false
```

- Only one `recovery_target*` may be set.
- Pick the newest backup whose end (`backup_manifest` / `backup_label`) is before the target. A target older than the
  backup cannot be reached. If commits ran during the backup, start-up stops with `FATAL: requested recovery stop
  point is before consistent recovery point`. After a quiet backup it promotes with no error at the first commit past
  the backup and keeps rows newer than the target, which is why the marker check below matters. Both ran on 18.6.
- After promotion, check a marker row committed just before the target and one just after.
- One table without touching the live cluster: `"$B/pg_restore" -h "$S" -p "$P" -d acme -t <table> --clean
  --if-exists "$R/dumps/<ts>.dump"`. For a point in time, restore into a scratch folder (section 8 setup),
  `pg_dump -t` the table there, and load it into the live cluster.

## 8. Weekly drill

The drill restores the latest chain into a scratch cluster and proves it starts and holds the data.

```bash
D=$(mktemp -d "$R/../drill.XXXX")                 # same volume: --clone is instant on APFS
DS=$HOME/.acme/drill-run && mkdir -p -m 700 "$DS"; DP=$((P + 1))
"$B/pg_combinebackup" --clone -o "$D/data" <latest chain>
"$B/pg_verifybackup" -q "$D/data"
cat > "$D/data/app.conf" <<EOF
listen_addresses = ''
port = $DP
unix_socket_directories = '$DS'
unix_socket_permissions = 0700
archive_mode = off
restore_command = 'cp "$R/archive/%f" "%p"'
recovery_target_action = 'promote'
EOF
touch "$D/data/recovery.signal"
T0=$(date +%s); "$B/pg_ctl" start -D "$D/data" -l "$D/drill.log" -w -t 600
"$B/psql" -X -h "$DS" -p "$DP" -d acme -Atc "select pg_is_in_recovery(), (select count(*) from pg_stat_database where checksum_failures > 0)"   # f|0
"$B/psql" -X -h "$DS" -p "$DP" -d acme -Atc "select count(*) from <key table>"   # compare with the live count at backup time
"$B/pg_ctl" stop -D "$D/data" -m fast -w; rm -rf "$D"
echo "{\"at\":\"$TS\",\"result\":\"PASS\",\"seconds\":$(( $(date +%s) - T0 ))}" >> "$R/drills.jsonl"
```

- `archive_mode = off` keeps the drill's new timeline and `.history` file out of the real archive.
- Any failed step appends `"result":"FAIL"` with the step name and the last log lines, and the app shows it.
- The restore time is the real recovery time objective (RTO); it grows with the archive since the last full.
