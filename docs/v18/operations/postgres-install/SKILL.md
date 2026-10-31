---
name: postgres-install
description: 'Installs PostgreSQL 18 on Linux, macOS and Windows: PGDG apt for Debian and Ubuntu with pg_createcluster, PGDG dnf for RHEL, Rocky, AlmaLinux and Fedora with postgresql-18-setup, Postgres.app, EDB and Homebrew on macOS, the EDB installer and winget unattended on Windows, initdb choices (locale provider, encoding, checksums, auth), client-only installs, verifying, uninstalling without losing data, and several major versions side by side. Use when someone asks how to install Postgres, set up a new server, install only psql, pick a locale, run two versions at once, or remove Postgres.'
metadata:
  tags:
  - postgres
  - install
  - pgdg
  - apt
  - dnf
  - postgres-app
  - windows
  - initdb
  - systemd
---

# PostgreSQL installation on Linux, macOS and Windows

Install PostgreSQL from the source that keeps it patched: the PGDG repositories on Linux, Postgres.app or the EDB
installer on macOS, the EDB installer (directly or through winget) on Windows. Decide the `initdb` options before the
first start: the cluster's default locale provider and encoding stay as `initdb` set them, and changing either means
a new cluster. An app that
ships its own private cluster follows `postgres-local-cluster`; containers follow `postgres-docker`. Paths, service
names and log locations per package are in [references/package-layouts.md](references/package-layouts.md).

## Step 0: find what is already installed

An existing server on port 5432 is the usual reason a new install will not start, so look first.

```bash
which -a psql pg_config postgres 2>/dev/null        # every copy on PATH, first one wins
pg_lsclusters                                       # Debian/Ubuntu: every cluster, version, port, status
ls /usr/pgsql-*/bin/postgres 2>/dev/null            # RHEL family PGDG installs
ls /Applications/Postgres.app/Contents/Versions     # macOS Postgres.app majors
```

On Windows, `Get-Service "postgresql*"` in PowerShell lists the EDB services (named `postgresql-x64-18` and so on).

## Choose an install source per OS

The install source decides who ships security fixes and where files land.

| OS | Use | Avoid for servers |
|---|---|---|
| Debian, Ubuntu | PGDG apt repository (`apt.postgresql.org`): every supported major, minors through `apt` | the distribution's package when it lacks your major |
| RHEL, Rocky, AlmaLinux, Fedora | PGDG dnf repository (`download.postgresql.org/pub/repos/yum`) | AppStream: EL 8.10 defaults to 10 with module streams up to 16, EL 9.8 to 13 with streams up to 18, EL 10.2 ships 16 and `postgresql18-server` (read on AlmaLinux, October 2026) |
| macOS, development | Postgres.app: several majors, PostGIS and pgvector included | Homebrew for anything other software depends on |
| macOS, a service | EDB installer (`/Library/PostgreSQL/18`, launchd service) | |
| Windows | EDB installer, or `winget install --id PostgreSQL.PostgreSQL.18 -e` (the same EDB package) | zip binaries, unless you embed Postgres in your own installer |

Homebrew's `postgresql@18` is keg-only and `brew upgrade` swaps its binaries under a running app: fine on a laptop,
wrong for software that must find the same binaries tomorrow (`postgres-local-cluster`).

## Linux: Debian and Ubuntu from the PGDG apt repository

The PGDG apt repository serves Debian 13 (trixie), 12 (bookworm), testing and unstable, and Ubuntu 26.10, 26.04 LTS,
24.04 LTS and 22.04 LTS (arm64 only on LTS releases). The packaged script adds the signed source for you.

```bash
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh     # add -y for no prompt
sudo apt install -y postgresql-18                                # server, contrib, client
# client tools only (psql, pg_dump, pg_restore, pg_isready ...):
sudo apt install -y postgresql-client-18
```

What the server package does on Debian and Ubuntu:

- Creates cluster `18/main` (started by systemd) on the first free port from 5432: data in `/var/lib/postgresql/18/main`,
  configuration in `/etc/postgresql/18/main/`, log in `/var/log/postgresql/postgresql-18-main.log`.
- Writes `pg_hba.conf` with `peer` locally and `scram-sha-256` over TCP; `postgres` has no password, so use
  `sudo -u postgres psql`.
- Enables data checksums (the 18 `initdb` default) and `ssl = on` with the `ssl-cert` snakeoil certificate.
- Runs each cluster as the systemd unit `postgresql@18-main`; `postgresql.service` starts every cluster whose
  `start.conf` says `auto`.

## Debian cluster tools: pg_createcluster, pg_ctlcluster, pg_dropcluster

The `postgresql-common` wrappers manage many clusters of many majors on one host; options after `--` go to
`initdb`.

```bash
sudo pg_createcluster 18 app --port 5433 -- --locale-provider=builtin --locale=C.UTF-8
sudo systemctl start postgresql@18-app           # or: sudo pg_ctlcluster 18 app start
pg_lsclusters                                    # Ver Cluster Port Status Owner Data directory Log file
sudo pg_ctlcluster 18 app stop
sudo pg_dropcluster 18 app                       # deletes that cluster's data and configuration
```

For defaults on every new cluster, set `initdb_options` in `/etc/postgresql-common/createcluster.conf` before
installing the server (it creates `main` at install time). Passing `-A`, `--auth`, `--auth-host` or
`--auth-local` after `--` leaves `pg_hba.conf` untouched; pass both `--auth-host` and `--auth-local`, or the other
one falls back to `trust`.

## Linux: RHEL, Rocky, AlmaLinux and Fedora from the PGDG dnf repository

The PGDG dnf repository serves EL 8, 9 and 10 (x86_64, aarch64, ppc64le), Fedora 43 and 44, and Amazon Linux 2023.
Install the repository RPM, then the server, then initialise; nothing starts on its own.

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql            # EL 8 only: hide the AppStream module
sudo dnf install -y postgresql18-server postgresql18-contrib
sudo PGSETUP_INITDB_OPTIONS="--locale-provider=builtin --locale=C.UTF-8 -E UTF8" \
  /usr/pgsql-18/bin/postgresql-18-setup initdb
sudo systemctl enable --now postgresql-18
```

- Binaries in `/usr/pgsql-18/bin` (not on `PATH`); data in `/var/lib/pgsql/18/data`.
- `postgresql-18-setup initdb` runs `initdb -A scram-sha-256 --auth-local=peer` plus `PGSETUP_INITDB_OPTIONS`, and
  needs systemd (it reads `PGDATA` from the unit).
- Contrib (`pg_stat_statements`, `pgcrypto` ...) is the separate `postgresql18-contrib` package.
- The unit `postgresql-18.service` sets `OOMScoreAdjust=-1000` with `PG_OOM_ADJUST_FILE` and
  `TimeoutStartSec=infinity`, so neither the OOM killer nor a long crash recovery stops the postmaster.
- Client only: `sudo dnf install -y postgresql18`.

## macOS: Postgres.app, the EDB installer and Homebrew

Postgres.app is the quickest correct setup for development: drag it to `/Applications`, open it, press Initialize.
Version 2.9.6 ships PostgreSQL 18.6 with PostGIS 3.6.3 (the "all versions" build adds 17 to 14, each in
`Contents/Versions/<major>/bin`). This command puts its tools on every user's `PATH`:

```bash
sudo mkdir -p /etc/paths.d && echo /Applications/Postgres.app/Contents/Versions/latest/bin | sudo tee /etc/paths.d/postgresapp
```

- Data lives in `~/Library/Application Support/Postgres/var-<major>`.
- The default `pg_hba.conf` uses `trust`: any local app connects as any role. Set passwords, then change `trust` to
  `scram-sha-256` (Server Settings, HBA file) before anything sensitive goes in.
- Scripts should name `Versions/18`, not `Versions/latest`, which moves when you install a new major.

The EDB installer puts a launchd service in `/Library/PostgreSQL/18` with a `postgres` macOS user.

## Windows: the EDB installer, winget and unattended installs

The EDB installer is the Windows build postgresql.org links to; winget's `PostgreSQL.PostgreSQL.18` package runs
the same installer. EDB tests 18 on Windows Server 2025 and 2022.

| Flag | Meaning |
|---|---|
| `--mode unattended --unattendedmodeui none` | no UI at all |
| `--superpassword <p>` | password of the `postgres` role; required unattended |
| `--serverport`, `--prefix`, `--datadir`, `--locale` | port, install folder, data folder, cluster locale |
| `--enable-components server,commandlinetools` | skip pgAdmin and StackBuilder |

The service is `postgresql-x64-18` running as `NT AUTHORITY\NetworkService`; every flag and default is in
[references/package-layouts.md](references/package-layouts.md).

This command installs the server and command-line tools silently through winget. `--override` hands its string to
the installer in place of the package's own switches (`--custom` adds to them), so it must repeat `--mode unattended`.

```powershell
winget install --id PostgreSQL.PostgreSQL.18 -e --accept-package-agreements --accept-source-agreements `
  --override "--mode unattended --unattendedmodeui none --superpassword `"$env:PG_SUPERPASS`" --serverport 5432 --enable-components server,commandlinetools"
Get-Service "postgresql*"
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -c "select version()"
```

- The installer does not add `bin` to `PATH`; add `C:\Program Files\PostgreSQL\18\bin` yourself.
- A password on the command line is visible to other processes while the installer runs; `--optionfile <file>`
  reads the options from a file instead.
- Settings that need a restart: `Restart-Service postgresql-x64-18`.

## initdb choices and what changing them later takes

`initdb` settles the cluster's default locale provider and encoding, and its data checksums and WAL segment size. The
four differ in what it takes to change them later. A new default locale or encoding needs a new cluster, reached by dump
and restore or logical replication, though one database can differ (below). Checksums can be switched while the
cluster is stopped with `pg_checksums --enable` or `--disable`. The WAL segment size can be changed on a stopped
cluster with `pg_resetwal --wal-segsize`, which the documentation treats as a last resort.

| Option | Choose | Why |
|---|---|---|
| `--locale-provider=builtin --locale=C.UTF-8` | default for new apps | code-point sort that never changes with glibc or ICU updates; no reindex after OS upgrades |
| `--locale-provider=icu --icu-locale=en-US` | when users need language-aware `ORDER BY` | same results on every OS; reindex text indexes when the ICU major changes |
| `--locale-provider=libc` (the default) | only to match an old cluster | sort order follows the OS C library; after a glibc upgrade, text indexes need `REINDEX` |
| `-E UTF8` | always | `SQL_ASCII` stores bytes without checking them |
| checksums | keep the 18 default (on) | `--no-data-checksums` only to `pg_upgrade` an old cluster that has none |
| `--auth-local=peer --auth-host=scram-sha-256` | servers | `trust` is `initdb`'s default and lets any local user in |
| `--wal-segsize` | keep 16 MB unless WAL volume is very high | later changes go through `pg_resetwal`, on a stopped cluster |

These commands create a cluster with each recommended setup; the builtin provider accepts only `C`, `C.UTF-8` and
`PG_UNICODE_FAST`.

```bash
initdb -D "$PGDATA" -U postgres --locale-provider=builtin --locale=C.UTF-8 -E UTF8 \
  --auth-local=peer --auth-host=scram-sha-256 --pwfile=/root/pg-initial-password
# language-aware sorting, the same on every OS:
initdb -D "$PGDATA" -U postgres --locale-provider=icu --icu-locale=en-US --locale=en_US.UTF-8 -E UTF8 \
  -A scram-sha-256 --pwfile=/root/pg-initial-password
```

One database can differ from the cluster default:
`CREATE DATABASE app TEMPLATE template0 LOCALE_PROVIDER icu ICU_LOCALE 'und' LOCALE 'C';`.

## Verify an install

Verification proves the server runs what you meant. `pg_isready` exits 0 when it accepts connections, 1 when it
rejects them (starting up), 2 on no response and 3 on bad parameters.

```bash
pg_isready -h /var/run/postgresql -p 5432; echo "exit=$?"
```

This query reads back what the server was initialised with:

```sql
SELECT version();
SELECT current_setting('data_checksums') AS checksums,
       current_setting('server_encoding') AS encoding,
       current_setting('password_encryption') AS password_encryption,
       current_setting('data_directory') AS data_directory;
SELECT datname, pg_encoding_to_char(encoding) AS encoding, datlocprovider, datlocale, datcollate
FROM pg_database ORDER BY datname;
SELECT type, database, user_name, address, auth_method FROM pg_hba_file_rules ORDER BY rule_number;
```

`datlocprovider` is `b` (builtin), `i` (ICU) or `c` (libc); a `trust` row on a shared machine is a finding.

## Several major versions side by side

Every package installs each major in a versioned path, so 17 and 18 coexist when each cluster has its own port and
data directory. The unversioned `psql` on `PATH` is whichever directory comes
first. `psql` works best with servers of its own major or older, and `pg_dump` dumps servers of its own major or
older, so use the newest client against mixed servers. Moving data between majors is `pg_upgrade`
(`postgres-operations`; on Debian, `pg_upgradecluster --method=upgrade`). Per-package details:
[references/package-layouts.md](references/package-layouts.md).

## Uninstall without losing data: does apt purge delete my databases?

Whether removing the Postgres package wipes your databases depends on the uninstaller. On Debian and Ubuntu,
`apt purge postgresql-18` deletes the data and configuration of every 18 cluster, while `apt remove postgresql-18`
keeps the clusters (they show as `down,binaries_missing`). `dnf remove`, the Postgres.app Trash, the EDB macOS
uninstaller and `brew uninstall` leave the data directory behind
([references/package-layouts.md](references/package-layouts.md)). Back up with `pg_dumpall` (or copy the stopped data
directory) before any uninstall.

## Gotchas

These are the install failures seen most often, each with its cause and fix.

1. **`Address already in use` in the server log.** Another server owns the port. Find it with Step 0, stop it, or
   give the new cluster another port.
2. **`apt install postgresql` installed an old major.** That is the distribution's package; add PGDG and install
   `postgresql-18`.
3. **`postgresql-18-setup: command not found` on RHEL.** Call it as `/usr/pgsql-18/bin/postgresql-18-setup`.
4. **`Peer authentication failed for user "postgres"`.** `peer` needs the OS user to equal the role. Use
   `sudo -u postgres psql`, or connect over TCP with a password.
5. **`invalid locale name "en_US.UTF-8" for builtin provider`.** The builtin provider takes only `C`, `C.UTF-8`
   and `PG_UNICODE_FAST`; pass `--builtin-locale` or `--locale` with one of those.
6. **`apt purge` deleted the database.** Purge drops the version's clusters; `apt remove` keeps them.
7. **Windows install fails on a non-ASCII user or machine name.** EDB supports ASCII names only.

## Checklist

Check these points before you call an install done.

- [ ] Installed from PGDG (Linux), Postgres.app or EDB (macOS), EDB or winget (Windows), at the current 18 minor.
- [ ] `initdb` options chosen on purpose: provider, `UTF8`, checksums on, no `trust` on shared hosts.
- [ ] The service starts at boot and `pg_isready` returns 0.
- [ ] The verify queries show the expected version, encoding, locale provider and `pg_hba` rules.
- [ ] Scripts call versioned binary paths, not whatever `psql` is first on `PATH`.
- [ ] Contrib is installed (`SELECT name FROM pg_available_extensions WHERE name = 'pg_stat_statements'`).
- [ ] A backup exists before any uninstall or second-major install.

## Anti-patterns in PostgreSQL installs

| Do not | Do this instead |
|---|---|
| install the distribution's older major for a new server | PGDG, or the EDB installer |
| leave `trust` on a shared machine | `peer` locally and `scram-sha-256` over TCP |
| accept the libc provider for a new cluster by default | builtin `C.UTF-8`, or ICU when sort order matters |
| call `psql` from scripts through `PATH` | a versioned path |
| run `apt purge` before a backup | `pg_dumpall` first; `apt remove` keeps the clusters |
| pass a password on an installer command line | `--optionfile`, with a file only you can read |

## See also

- `postgres-local-cluster`: one private cluster per app.
- `postgres-docker` and `postgres-kubernetes`: containers and operators.
- `postgres-extensions-install`: adding extensions.
- `postgres-operations`: configuration and major upgrades.
- `postgres-os-kernel-tuning`: preparing the host.
- `postgres-security-roles`: `pg_hba.conf` and roles.

## Sources

- postgresql.org: download pages for Debian, Ubuntu, Red Hat (with its `yum.js` script generator), macOS, Windows;
  docs/18 `app-initdb`, `locale`, `app-pg-isready`, `app-psql`, `app-pgdump`, `release-18`; support/versioning.
- Debian `postgresql-common`: `pg_createcluster(1)`, `pg_upgradecluster(1)`, `createcluster.conf`, `postgresql@.service`.
- postgresapp.com: install and downloads pages. formulae.brew.sh: `postgresql@18`.
- enterprisedb.com/docs: PostgreSQL installer command line parameters, Windows, uninstalling; EnterpriseDB/edb-installers
  `server/pgserver.xml.in` (service name and account defaults); winget manifest `PostgreSQL.PostgreSQL.18` 18.6-5;
  learn.microsoft.com: `winget install`, `Get-Service`.
- Run on 18.6 (Postgres.app): `initdb` with builtin, ICU, checksums and auth options, the verify queries, `pg_isready`
  exit codes. In containers: PGDG install on Debian 13 (cluster tools, `remove` versus `purge`) and AlmaLinux 9
  (packages, unit file, `postgresql-18-setup`, logging defaults).
