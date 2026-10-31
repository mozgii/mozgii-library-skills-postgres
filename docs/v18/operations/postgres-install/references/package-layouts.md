---
title: PostgreSQL package layouts, side-by-side majors and uninstalling
author: MOZGII, Inc.
lang: en
---

# PostgreSQL package layouts, side-by-side majors and uninstalling

This reference lists where each PostgreSQL 18 package puts binaries, data, configuration, logs and services on
Linux, macOS and Windows, how to run two majors on one host, and what each uninstaller does to the data.

## Contents

The sections of this reference:

- File locations per package
- Service names and how to control them
- EDB installer flags for unattended installs
- Several major versions side by side
- Uninstalling each package and what happens to the data

## File locations per package

Each package uses its own layout; scripts and agents should read the path from this table instead of guessing.

| Package | Binaries | Data directory | Configuration | Server log |
|---|---|---|---|---|
| PGDG apt (Debian, Ubuntu) | `/usr/lib/postgresql/18/bin` (wrappers in `/usr/bin`) | `/var/lib/postgresql/18/main` | `/etc/postgresql/18/main/` | `/var/log/postgresql/postgresql-18-main.log` |
| PGDG dnf (RHEL family, Fedora) | `/usr/pgsql-18/bin` | `/var/lib/pgsql/18/data` | inside the data directory | `log/postgresql-<day>.log` inside the data directory |
| Postgres.app | `/Applications/Postgres.app/Contents/Versions/18/bin` | `~/Library/Application Support/Postgres/var-18` | inside the data directory | read `log_directory` |
| EDB, macOS | `/Library/PostgreSQL/18/bin` | `/Library/PostgreSQL/18/data` | inside the data directory | read `log_directory` |
| EDB, Windows | `C:\Program Files\PostgreSQL\18\bin` | `C:\Program Files\PostgreSQL\18\data` | inside the data directory | read `log_directory` |
| Homebrew `postgresql@18` | `$HOMEBREW_PREFIX/opt/postgresql@18/bin` | `$HOMEBREW_PREFIX/var/postgresql@18` | inside the data directory | `$HOMEBREW_PREFIX/var/log/postgresql@<major>.log` |

This query asks a running server where its files are, whatever the package:

```sql
SELECT name, setting FROM pg_settings
WHERE name IN ('data_directory', 'config_file', 'hba_file', 'log_directory', 'unix_socket_directories', 'port');
```

`pg_config --bindir --sharedir --pkglibdir` prints the binary, share (extension control files) and library
directories of the build that `pg_config` belongs to.

## Service names and how to control them

The service manager starts PostgreSQL at boot; each package registers it under a different name.

| Package | Service | Start, stop, reload |
|---|---|---|
| PGDG apt | `postgresql@18-main` (one per cluster), `postgresql.service` (all `auto` clusters) | `systemctl start postgresql@18-main`; `pg_ctlcluster 18 main reload` |
| PGDG dnf | `postgresql-18` | `systemctl enable --now postgresql-18`; `systemctl reload postgresql-18` |
| Postgres.app | the app itself (menu bar) | Start and Stop buttons; optional start at login |
| EDB, macOS | a launchd daemon in `/Library/LaunchDaemons/` | `sudo launchctl` against that plist |
| EDB, Windows | `postgresql-x64-18`, running as `NT AUTHORITY\NetworkService` | `Restart-Service postgresql-x64-18` |
| Homebrew | a `brew services` launchd job | `brew services start postgresql@18` |

On Debian and Ubuntu, `start.conf` in the cluster's configuration directory holds `auto`, `manual` or `disabled`;
run `systemctl daemon-reload` after editing it. On Windows, `pg_ctl register -N <name> -U <account> -D <datadir>`
registers a service for a cluster you created yourself with `initdb` (start type `-S auto` or `demand`).

## EDB installer flags for unattended installs

The EDB installer for macOS and Windows takes these command-line flags; `--help` prints the full list.

| Flag | Default | Notes |
|---|---|---|
| `--mode` | `qt` | `unattended` on both OSes; also `win32` (Windows), `osx` and `text` (macOS) |
| `--unattendedmodeui` | `minimal` | `none`, `minimal`, `minimalWithDialogs` |
| `--superaccount` | `postgres` | bootstrap superuser name |
| `--superpassword` | none | required for unattended installs |
| `--serverport` | `5432` | |
| `--prefix` | `/Library/PostgreSQL/<major>`, `C:\Program Files\PostgreSQL\<major>` | install directory |
| `--datadir` | `<prefix>/data` | data directory |
| `--locale` | detected by `initdb` | cluster locale; non-ASCII Windows names are converted to BCP 47 |
| `--servicename` | `postgresql-x64-<major>` on Windows | 6 to 50 characters: letters, digits, `_`, `.`, `-` |
| `--serviceaccount` | `NT AUTHORITY\NetworkService` on Windows, `postgres` on macOS | `--servicepassword` (Windows) when it is a real account |
| `--enable-components`, `--disable-components` | all | `server`, `pgAdmin`, `stackbuilder`, `commandlinetools` |
| `--install_runtimes` | `1` | Visual C++ runtime |
| `--create_shortcuts` | `1` | menu shortcuts |
| `--extract-only` | `0` | unpack binaries without installing a service |
| `--optionfile` | none | read options from a file instead of the command line |

The winget package `PostgreSQL.PostgreSQL.18` runs the same installer with `--mode unattended --unattendedmodeui none`
for `--silent` and accepts `--override` (replace those switches) or `--custom` (add to them).

## Several major versions side by side

Every package above installs each major in a versioned path, so 17 and 18 can coexist; each cluster needs its own
port and data directory.

| Package | How two majors coexist |
|---|---|
| PGDG apt | install `postgresql-17` and `postgresql-18`; the second `main` cluster takes port 5433; `pg_lsclusters` lists both |
| PGDG dnf | units `postgresql-17` and `postgresql-18`, data in `/var/lib/pgsql/17/data` and `/var/lib/pgsql/18/data`; set `port` in one of them |
| Postgres.app | one server per major in the sidebar, each with its own port |
| EDB | each installer asks for a port and creates its own service and data directory |
| Homebrew | `postgresql@17` and `postgresql@18` are keg-only; call each by its `opt` path |

Debian's `pg_upgradecluster 17 main` upgrades a cluster to the newest installed major and copies its configuration;
it uses `pg_dump` by default and `pg_upgrade` with `--method=upgrade` (or `link`, `clone`). Everywhere else run
`pg_upgrade` directly (`postgres-operations`).

## Uninstalling each package and what happens to the data

Uninstallers differ in whether they delete the data directory. Back up with `pg_dumpall` (or copy the stopped data
directory) before any of these.

| Package | Remove | Data afterwards |
|---|---|---|
| PGDG apt | `sudo apt remove postgresql-18` | kept; `pg_lsclusters` shows the cluster as `down,binaries_missing` |
| PGDG apt | `sudo apt purge postgresql-18` | deleted: `/var/lib/postgresql/18/<cluster>` and `/etc/postgresql/18/<cluster>` |
| PGDG dnf | `sudo dnf remove postgresql18-server postgresql18` | `/var/lib/pgsql/18` stays until you delete it |
| Postgres.app | quit, drag to Trash, `defaults delete com.postgresapp.Postgres2`, `sudo rm /etc/paths.d/postgresapp` | `~/Library/Application Support/Postgres` stays |
| EDB, macOS | `open /Library/PostgreSQL/18/uninstall-postgresql.app/Contents/MacOS/installbuilder.sh` | data directory and the `postgres` macOS user stay |
| EDB, Windows | Control Panel, Uninstall or change a program, PostgreSQL 18 | not documented by EDB; check the data folder afterwards |
| Homebrew | `brew uninstall postgresql@18`, then `brew cleanup --prune-prefix` | `$HOMEBREW_PREFIX/var/postgresql@18` stays |

After removing a server, make sure no `postgres` process still holds the port before installing another one.
