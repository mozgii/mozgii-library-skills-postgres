---
name: postgres-os-kernel-tuning
description: 'Tunes the operating system under PostgreSQL 18: Linux huge pages with shared_memory_size_in_huge_pages, transparent huge pages off, vm.overcommit_memory and the OOM killer, swappiness and dirty page writeback, file systems and noatime, I/O schedulers, io_method worker versus io_uring, NUMA, open-file limits, systemd units and RemoveIPC, macOS and Windows notes, sizing CPU, RAM and disks, and measuring with pg_test_fsync and pg_test_timing. Use when a Linux database host is set up, the postmaster is killed by the OOM killer, huge pages do not take effect, checkpoints cause latency spikes, io_uring will not start, or someone asks how big a Postgres server must be.'
metadata:
  tags:
  - postgres
  - linux
  - kernel
  - huge-pages
  - sysctl
  - io-uring
  - oom-killer
  - sizing
  - pg-test-fsync
---

# PostgreSQL OS and kernel tuning

Tune the host only after measuring it, and only on a host that runs nothing but PostgreSQL. The changes that matter,
in order: huge pages for `shared_buffers` above a few GB, transparent huge pages off, the OOM killer kept away from
the postmaster, honest fsync on the WAL disk, and enough file and process limits. Server parameters such as
`shared_buffers` and `work_mem` are in `postgres-operations`; this skill is the OS underneath. A read-only report of
every value below is [scripts/linux-host-check.sh](scripts/linux-host-check.sh) (its main reads are inline under
Verify); ready-made sysctl and systemd files are in [references/linux-host-setup.md](references/linux-host-setup.md).

## Step 0: read what the server and the OS have now

The server reports the OS-facing values it computed at start, including the size of its shared memory in huge
pages; this ran on 18.6:

```sql
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('shared_buffers', 'huge_pages', 'huge_pages_status', 'huge_page_size', 'shared_memory_size',
               'shared_memory_size_in_huge_pages', 'shared_memory_type', 'io_method', 'io_workers',
               'effective_io_concurrency', 'max_files_per_process', 'wal_sync_method',
               'checkpoint_flush_after', 'num_os_semaphores')
ORDER BY name;
SELECT enumvals FROM pg_settings WHERE name = 'io_method';     -- {sync,worker,io_uring} when built with liburing
```

`huge_pages_status` says whether huge pages are in use, not what was asked for. On the OS side run
`bash linux-host-check.sh /var/lib/postgresql/18/main`.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

## Sizing CPU, RAM and disks for a workload

Size from the workload's working set and write rate, then confirm with `pg_stat_io` and `pg_test_fsync`; each
resource limits something different.

| Resource | What it limits | How to size it |
|---|---|---|
| CPU cores | queries running at once (one core per backend, plus parallel workers) | peak active queries (not connections) near the core count; pool the rest (`postgres-connection-pooling`) |
| RAM | how much hot data stays cached; in-memory sorts and hashes | hot tables and indexes, plus `work_mem` times active sort or hash nodes, plus `maintenance_work_mem` per vacuum or index build |
| WAL disk | commit rate | single-session commits per second are bounded by the disk's fsync rate (measure with `pg_test_fsync`) |
| Data disk | reads that miss the cache, checkpoint and vacuum writes | IOPS and throughput from `pg_stat_io`; low latency matters more than peak bandwidth |
| Capacity | growth and maintenance | at least 2x the largest table free for `VACUUM FULL`, `pg_repack` or a copy-mode `pg_upgrade`, plus WAL retention |

This query shows which process types read and write the most since the last stats reset (times need
`track_io_timing = on`):

```sql
SELECT backend_type, object, context, reads, read_bytes, read_time, writes, write_bytes, write_time, fsyncs
FROM pg_stat_io
WHERE coalesce(reads, 0) + coalesce(writes, 0) + coalesce(fsyncs, 0) > 0
ORDER BY coalesce(read_bytes, 0) + coalesce(write_bytes, 0) DESC
LIMIT 10;
```

## Linux huge pages for shared memory

Huge pages map PostgreSQL's main shared memory with 2 MB (or 1 GB) pages, which shrinks page tables and saves CPU
when `shared_buffers` is large. PostgreSQL asks for them by default (`huge_pages = try`) but the kernel has none
reserved, so it silently falls back. Reserve exactly what the server needs:

```bash
# on a STOPPED server (with the server running, postgres -C fails: lock file "postmaster.pid" already exists)
sudo -u postgres /usr/lib/postgresql/18/bin/postgres -D /var/lib/postgresql/18/main \
  -c config_file=/etc/postgresql/18/main/postgresql.conf -C shared_memory_size_in_huge_pages
grep ^Hugepagesize /proc/meminfo                    # the default huge page size, often 2048 kB
echo 'vm.nr_hugepages = 4200' | sudo tee /etc/sysctl.d/40-postgresql-hugepages.conf   # value from -C, plus margin
sudo sysctl --system
grep -E '^HugePages_(Total|Free)' /proc/meminfo
```

Then set `huge_pages = on` so the server refuses to start without them, start it, and check that
`SHOW huge_pages_status;` returns `on`. A running server shows the number with `SHOW shared_memory_size_in_huge_pages`
(128 MB `shared_buffers` gave 150 MB of shared memory, 75 huge pages, in a Linux container).

- Reserve at boot (`hugepages=N` on the kernel command line, or the sysctl file): later, fragmented memory may give
  fewer pages than asked.
- `huge_page_size = 1GB` (Linux only) needs pages in `/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`.
- Huge pages need `shared_memory_type = mmap` (the default); resize them when `shared_buffers` or
  `max_connections` changes.

## Transparent huge pages off

Transparent huge pages (THP) let the kernel merge normal pages behind PostgreSQL's back; the PostgreSQL docs
discourage them because of reported performance drops. Check and turn them off:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled     # always [madvise] never: the bracket is current
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

The `echo` lasts until reboot; make it permanent with `transparent_hugepage=never` on the kernel command line, or
the systemd unit in the reference.

## Memory overcommit and the OOM killer

Linux overcommits memory by default (`vm.overcommit_memory = 0`), and under pressure the OOM killer may pick any
server process. If it kills the postmaster, all connections eventually end and PostgreSQL needs a restart. If it kills
a child, PostgreSQL normally closes the remaining connections, then recovers by itself with `restart_after_crash` on
or shuts down with it off. Two defences, used together on a dedicated host:

1. Keep the postmaster out of the OOM killer's reach: start it with `oom_score_adj` -1000 and let backends return to
   0 through `PG_OOM_ADJUST_FILE`. The PGDG RHEL unit already sets `OOMScoreAdjust=-1000`,
   `PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj` and `PG_OOM_ADJUST_VALUE=0`; Debian's `pg_ctlcluster` writes -900
   for the postmaster and sets `PG_OOM_ADJUST_FILE` for its children.
2. Strict accounting, `vm.overcommit_memory = 2`: the kernel refuses allocations beyond swap plus
   `vm.overcommit_ratio` percent of RAM (default 50), so a greedy query gets `out of memory` instead of a kill.

```bash
grep -E '^(CommitLimit|Committed_AS)' /proc/meminfo   # Committed_AS must stay well below CommitLimit
```

With mode 2 and little swap, the default ratio of 50 caps commits near half the RAM and `fork` fails (`could not
fork new process for connection`). Raise `vm.overcommit_ratio` (for example 80) and watch `Committed_AS`.

## Swappiness and dirty page writeback

`vm.swappiness` (0 to 200, kernel default 60) sets how readily the kernel swaps process memory rather than drop page
cache; dedicated database hosts commonly use 1 to 10 and keep some swap as a safety margin.

Dirty writeback decides how much written data waits in the page cache: `vm.dirty_background_ratio` (default 10) and
`vm.dirty_ratio` (default 20), as percentages of available memory, or the `_bytes` counterparts (setting one zeroes
the other). On hosts with hundreds of GB of RAM the percentages allow tens of GB of dirty data, which a checkpoint's
fsync then flushes in one stall. PostgreSQL already limits its own dirty data on Linux with
`checkpoint_flush_after` (256 kB) and `bgwriter_flush_after` (512 kB); if checkpoints still cause latency spikes, set
`vm.dirty_background_bytes` to a few hundred MB and measure again.

## File systems, mount options and the I/O scheduler

Put data and WAL on ext4 or XFS on local SSD or NVMe, ideally WAL on its own device (`initdb -X`), mounted with
`noatime`. Never disable `fsync` or `full_page_writes` on data you keep, or use storage whose write cache can lose
acknowledged writes.

The block I/O scheduler is per device in `/sys/block/<dev>/queue/scheduler`; the bracketed name is active, and the
choices are `mq-deadline`, `none`, `bfq` and `kyber`. `none` passes requests straight to the device and suits fast
NVMe; `mq-deadline` suits SATA SSDs and disks. Change it with a udev rule (reference) and measure before and after.

## Asynchronous I/O in PostgreSQL 18: io_method and io_uring

PostgreSQL 18 reads ahead asynchronously for sequential scans, bitmap heap scans and vacuum. `io_method` (restart
required) selects how:

| `io_method` | How | Where |
|---|---|---|
| `worker` (default) | `io_workers` background processes (default 3, reload to change) do the reads | every OS |
| `io_uring` | the kernel's io_uring interface, no extra processes | Linux builds with `--with-liburing` (the PGDG apt and dnf builds and the Docker images have it) |
| `sync` | the pre-18 synchronous behaviour | for comparison or troubleshooting |

io_uring fails at start with `could not setup io_uring queue: Operation not permitted` when the kernel forbids it
(`kernel.io_uring_disabled` 1 or 2) or a seccomp profile blocks it, as Docker's default profile does.
`effective_io_concurrency` (default 16) sets how far ahead each scan reads; `pg_aios` lists I/O in flight.

## NUMA

On multi-socket hosts memory is split into NUMA nodes. Keep `vm.zone_reclaim_mode = 0` (the kernel default), which
the kernel docs advise for workloads that benefit from caching. PostgreSQL 18 built `--with-libnuma` adds
`pg_numa_available()` and the views `pg_shmem_allocations_numa` and `pg_buffercache_numa`, which show how shared
memory spreads across nodes.

## Limits: open files, processes, semaphores and RemoveIPC

PostgreSQL caps open files per backend with `max_files_per_process` (default 1000), so systemd's default hard
`LimitNOFILE` (524288) is rarely the problem. Linux uses POSIX semaphores; System V semaphores (`num_os_semaphores`)
matter on macOS and other platforms.

- systemd's logind removes a user's IPC objects at its last logout when `RemoveIPC=yes`; a `postgres` user that is
  not a system user then loses shared memory segments (`could not remove shared memory segment`). Create it with
  `useradd -r`, or set `RemoveIPC=no` in `/etc/systemd/logind.conf`.
- Huge pages may also need the server's group in `vm.hugetlb_shm_group` and permission to lock memory with
  `ulimit -l` (`LimitMEMLOCK=` in systemd).

## macOS notes

macOS runs PostgreSQL for development and desktop apps. Shared memory comes from `mmap`, so the `kern.sysv.shm*`
limits matter only with `shared_memory_type = sysv`; huge pages are not supported (`huge_pages_status` is `off`,
`shared_memory_size_in_huge_pages` is -1), and `checkpoint_flush_after` and `bgwriter_flush_after` are 0. The
default `wal_sync_method` (`open_datasync`) does not stop the drive's write cache; `fsync_writethrough` does. On
an Apple SSD that measured about 320 writes per second against about 40,000 for plain `fsync`, which is the price of
durability across power loss. Desktop apps that must survive a power cut set `wal_sync_method = fsync_writethrough`.

## Windows notes

Windows calls huge pages "large pages": `huge_pages = on` needs the "Lock pages in memory" right for the service
account (Group Policy, `gpedit.msc`), and from a command prompt the server must run elevated. `wal_sync_method`
defaults to `open_datasync`; disable the disk's write caching or use `fsync`/`fdatasync` (NTFS) for durability.
`io_method = io_uring` does not exist on Windows, and `shared_preload_libraries` are loaded again by every backend
there.

## Measuring with pg_test_fsync and pg_test_timing

`pg_test_fsync` measures how many WAL flushes per second each `wal_sync_method` achieves on a given file system; run
it on the WAL volume (`-f` names a file there, `-s` seconds per test, default 5). This is part of a run on an Apple
SSD, 1 second per test:

```text
        open_datasync                     24660.464 ops/sec      41 usecs/op
        fdatasync                         43736.299 ops/sec      23 usecs/op
        fsync                             40593.865 ops/sec      25 usecs/op
        fsync_writethrough                  321.962 ops/sec    3106 usecs/op
```

Tens of thousands of flushes per second come from a cache that is either power-loss protected (enterprise SSD,
battery-backed controller) or not honest about durability; know which one you have. `pg_test_timing` (`-d` seconds,
default 3) checks the clock source that `EXPLAIN ANALYZE` and `track_io_timing` use: good systems show over 90% of
calls under one microsecond (16 ns per loop on the same Mac). A slow clock source, such as `acpi_pm` instead of `tsc`
on Linux, inflates `EXPLAIN ANALYZE` times.

## Verify a tuned Linux host

These reads change nothing and work without the script file. They ran in a Debian container with PostgreSQL 18.6;
values from a container describe its host kernel. Reboot once before you trust them, so anything set only at run time
shows up as missing.

```bash
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness vm.nr_hugepages vm.dirty_background_bytes
cat /sys/kernel/mm/transparent_hugepage/enabled
grep -E '^(HugePages_(Total|Free)|CommitLimit|Committed_AS)' /proc/meminfo
cat /proc/"$(head -1 "$PGDATA/postmaster.pid")"/oom_score_adj      # -900 or -1000 for the postmaster
findmnt -no FSTYPE,OPTIONS --target "$PGDATA"                      # noatime present
psql -X -Atc 'SHOW huge_pages_status'                              # on
```

`pg_test_fsync -f <file on the WAL volume>` must give the commit rate you sized for. Only a real power-loss test on a
staging box proves that a write cache is honest.

## Gotchas

These are the OS-level failures seen most often, each with its cause and fix.

1. **`huge_pages_status` is `off` although `huge_pages = try`.** No huge pages reserved, or too few. Reserve
   `shared_memory_size_in_huge_pages` pages and set `huge_pages = on` to make it fail loudly.
2. **`postgres -C shared_memory_size_in_huge_pages` fails with `lock file "postmaster.pid" already exists`.** It
   needs a stopped server; on a running one use `SHOW`.
3. **The postmaster was killed: `Out of Memory: Killed process ... (postgres)`.** Set `OOMScoreAdjust=-1000` with
   `PG_OOM_ADJUST_FILE`, and consider `vm.overcommit_memory = 2` with a sized ratio.
4. **`could not fork new process for connection: Cannot allocate memory` after enabling strict overcommit.**
   `vm.overcommit_ratio` is too low for the RAM; raise it and check `CommitLimit`.
5. **`could not setup io_uring queue: Operation not permitted`.** A seccomp profile or `kernel.io_uring_disabled`
   blocks io_uring; keep `io_method = worker`.
6. **Random `could not remove shared memory segment` warnings.** `RemoveIPC=yes` and a non-system `postgres`
   user; fix either.
7. **Latency spikes every checkpoint.** Too much dirty page cache flushed at once; check `pg_stat_checkpointer`,
   spread checkpoints (`postgres-operations`), then lower `vm.dirty_background_bytes`.

## Anti-patterns in host tuning

Most of these come from copied sysctl lists.

| Do not | Do instead |
|---|---|
| Copy a sysctl file from a blog | Measure, change one setting, and measure again |
| Set `fsync = off` or `full_page_writes = off` on data you keep | Keep both on; move WAL to a faster device |
| Tune a host shared with other services | Dedicate the host first; these settings assume Postgres owns it |
| Leave `huge_pages = try` and assume they are in use | Set `on` and read `huge_pages_status` |
| Set `vm.swappiness = 0` and remove swap | Use 1 to 10 and keep some swap as a margin |
| Set `vm.overcommit_memory = 2` and keep the default ratio | Raise `vm.overcommit_ratio` and watch `Committed_AS` |

## Checklist

Check these points before you call a database host tuned.

- [ ] Huge pages reserved from `shared_memory_size_in_huge_pages`, `huge_pages = on`, `huge_pages_status = on`.
- [ ] Transparent huge pages `never` (or `madvise`), set permanently.
- [ ] Postmaster `oom_score_adj` -900 or -1000, backends 0; overcommit policy chosen and `CommitLimit` checked.
- [ ] Swappiness and dirty settings chosen on purpose and recorded in `/etc/sysctl.d/`.
- [ ] Data and WAL on local SSD or NVMe with `noatime`; write cache honest or power-loss protected
      (`pg_test_fsync` run on the WAL volume).
- [ ] `io_method` tested: `worker` by default, `io_uring` only where the kernel and container allow it.
- [ ] `postgres` is a system user, or `RemoveIPC=no`.

## See also

Related skills in this library, each one works on its own:

- `postgres-operations`: `shared_buffers`, `work_mem` and the rest of the server side.
- `postgres-install`: packages and service units per OS.
- `postgres-local-cluster`: desktop durability on macOS.
- `postgres-monitoring-observability`: watching I/O and checkpoints.
- `postgres-pg18-features`: what asynchronous I/O changed.

## Sources

- postgresql.org docs/18: `kernel-resources`, `runtime-config-resource`, `runtime-config-wal`, `wal-reliability`,
  `server-start`, `pgtestfsync`, `pgtesttiming`, `release-18` (AIO, NUMA).
- docs.kernel.org: `admin-guide/sysctl/vm`, `admin-guide/sysctl/kernel`, `admin-guide/mm/transhuge`,
  `admin-guide/mm/hugetlbpage`, `mm/overcommit-accounting`, `block/switching-sched`; kernel source for the
  `swappiness`, `dirty_*` and `overcommit_ratio` defaults. man7.org: `systemd.exec(5)`, `logind.conf(5)`,
  `sysctl.d(5)`, `mount(8)`, `udevadm(8)`.
- PGDG `postgresql-18.service` (read in AlmaLinux 9) and Debian `pg_ctlcluster` source (OOM handling).
- Run on 18.6: Step 0 and `pg_stat_io` queries, `postgres -C` on running and stopped clusters, `pg_test_fsync` and
  `pg_test_timing` on macOS; in `postgres:18`: huge page sizing, flush defaults, io_uring under seccomp, the script.
