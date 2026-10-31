---
title: Linux host setup files for a PostgreSQL server
author: MOZGII, Inc.
lang: en
---

# Linux host setup files for a PostgreSQL server

This reference holds the files that apply the Linux settings from `postgres-os-kernel-tuning` on a dedicated
PostgreSQL host: a sysctl file, huge pages, a unit that turns transparent huge pages off, a systemd drop-in for the
PostgreSQL service, a udev rule for the I/O scheduler, the `fstab` mount options, and the checks after a reboot. The
values are starting points for a dedicated host with 64 GB of RAM and `shared_buffers = 16GB`; recompute them for
yours.

## Contents

The files, in the order you apply them:

- sysctl settings in /etc/sysctl.d
- Huge pages sized from the server
- Transparent huge pages off at boot
- systemd drop-in for the PostgreSQL service
- I/O scheduler with a udev rule
- Mount options in /etc/fstab
- Checks after a reboot

## sysctl settings in /etc/sysctl.d

`sysctl.d` files are read at boot in name order, and `sudo sysctl --system` applies them now. Each value below is
a starting point; the reasons are in the skill.

```ini
# /etc/sysctl.d/60-postgresql.conf
vm.swappiness = 5
vm.overcommit_memory = 2
vm.overcommit_ratio = 80             # CommitLimit = swap + 80% of RAM; check Committed_AS after load
vm.dirty_background_bytes = 268435456  # 256 MB: start background writeback early
vm.dirty_bytes = 1073741824          # 1 GB: writers block beyond this
vm.zone_reclaim_mode = 0
```

Setting a `_bytes` value zeroes its `_ratio` counterpart and the other way round, so keep only one of each pair in
your files. Skip `vm.overcommit_memory = 2` on hosts that also run other software with large virtual reservations
(JVMs, some monitoring agents): they may fail to start.

## Huge pages sized from the server

The number of huge pages comes from the server itself. Stop the server, ask it, reserve that many plus a small
margin, then require them.

```bash
sudo systemctl stop postgresql@18-main                    # RHEL: postgresql-18
N=$(sudo -u postgres /usr/lib/postgresql/18/bin/postgres -D /var/lib/postgresql/18/main \
      -c config_file=/etc/postgresql/18/main/postgresql.conf -C shared_memory_size_in_huge_pages)
echo "vm.nr_hugepages = $((N + N / 50 + 8))" | sudo tee /etc/sysctl.d/40-postgresql-hugepages.conf
sudo sysctl --system
grep -E '^HugePages_(Total|Free)' /proc/meminfo           # Total must reach the value; reboot if fragmented
echo "huge_pages = on" | sudo tee /etc/postgresql/18/main/conf.d/hugepages.conf   # RHEL: postgresql.conf in PGDATA
sudo systemctl start postgresql@18-main
sudo -u postgres psql -Atc "SHOW huge_pages_status"       # on
```

On RHEL the paths are `/usr/pgsql-18/bin/postgres` and `-D /var/lib/pgsql/18/data` without `config_file`. Repeat
the sizing after changing `shared_buffers`, `max_connections`, `max_worker_processes` or `wal_buffers`.

## Transparent huge pages off at boot

A kernel command-line parameter is the most reliable way: add `transparent_hugepage=never` to the kernel command
line with your distribution's boot loader tool (on Debian and Ubuntu: `GRUB_CMDLINE_LINUX` in `/etc/default/grub`,
then `update-grub`). Where the command line cannot change, this unit writes the sysfs files at every boot:

```ini
# /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable transparent huge pages for PostgreSQL
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=postgresql.service postgresql-18.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
```

Enable it and check the result:

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now disable-thp.service
cat /sys/kernel/mm/transparent_hugepage/enabled            # always madvise [never]
```

## systemd drop-in for the PostgreSQL service

A drop-in changes the packaged unit without editing it, and survives package upgrades. Both packaged units already
set the OOM protection and a one-hour `TimeoutStopSec`: the PGDG RHEL unit `OOMScoreAdjust=-1000` with
`PG_OOM_ADJUST_FILE`, Debian's `postgresql@.service` `OOMScoreAdjust=-900` with `pg_ctlcluster` setting
`PG_OOM_ADJUST_FILE`. This drop-in adds the locked-memory limit the PostgreSQL docs say huge pages may need:

```ini
# /etc/systemd/system/postgresql@<major>-main.service.d/override.conf   (RHEL: postgresql-18.service.d/override.conf)
[Service]
LimitMEMLOCK=infinity
```

Reload systemd, restart, and confirm the limits and the postmaster's OOM score:

```bash
sudo systemctl daemon-reload && sudo systemctl restart postgresql@18-main
systemctl show postgresql@18-main -p OOMScoreAdjust -p LimitMEMLOCK -p TimeoutStopUSec
cat /proc/$(head -1 /var/lib/postgresql/18/main/postmaster.pid)/oom_score_adj   # -900 (Debian) or -1000 (RHEL)
```

If the `postgres` account is not a system user (created without `useradd -r`), also set `RemoveIPC=no` in
`/etc/systemd/logind.conf` and restart `systemd-logind`.

## I/O scheduler with a udev rule

The scheduler is set per device and resets at boot; a udev rule applies it to every matching device as it appears.
This rule picks `none` for NVMe and `mq-deadline` for other non-rotational SCSI or SATA devices:

```text
# /etc/udev/rules.d/60-io-scheduler.rules
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
```

Apply the rule to the devices already present:

```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=block
cat /sys/block/nvme0n1/queue/scheduler                    # [none] mq-deadline kyber bfq
```

## Mount options in /etc/fstab

`noatime` stops reads from writing access times. A separate file system for WAL keeps a WAL burst from filling the
data volume and gives WAL its own I/O queue.

```text
# /etc/fstab
UUID=<data-fs-uuid>  /var/lib/postgresql          xfs   defaults,noatime  0 0
UUID=<wal-fs-uuid>   /var/lib/postgresql/wal      xfs   defaults,noatime  0 0
```

Create the cluster with WAL on the second file system (`initdb -X /var/lib/postgresql/wal/18/main`, or
`pg_createcluster ... -- -X ...` on Debian). Never add a mount option that disables write barriers or cache flushes.

## Checks after a reboot

Run the read-only report from the skill's `scripts/linux-host-check.sh` and compare it with what you set.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

These lines are the short version:

```bash
sysctl vm.swappiness vm.overcommit_memory vm.overcommit_ratio vm.dirty_background_bytes vm.nr_hugepages
grep -E '^(HugePages_Total|HugePages_Free|CommitLimit|Committed_AS)' /proc/meminfo
cat /sys/kernel/mm/transparent_hugepage/enabled
sudo -u postgres psql -Atc "SELECT name || ' = ' || setting FROM pg_settings WHERE name IN ('huge_pages_status','io_method','shared_memory_size_in_huge_pages')"
```
