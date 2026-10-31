#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# Rehearse the checks of a major upgrade against a RUNNING old cluster, without changing it.
# Creates a new, empty cluster that matches the old one (encoding, locale provider, checksums) and runs
# pg_upgrade --check. Usage:
#   pg-upgrade-check.sh <old-bindir> <new-bindir> <old-datadir> <new-datadir> <socket-dir> <old-port> [pg_upgrade options...]
# Example: pg-upgrade-check.sh /usr/lib/postgresql/17/bin /usr/lib/postgresql/18/bin \
#            /var/lib/postgresql/17/main /var/lib/postgresql/18/main /var/run/postgresql 5432 --link --jobs 4
# The install user comes from PGUSER (default postgres). <new-datadir> must not exist yet.
# Linux and macOS; on Windows run pg_upgrade.exe --check by hand (no -s socket directory there).
set -euo pipefail
usage() { echo "usage: pg-upgrade-check.sh <old-bindir> <new-bindir> <old-datadir> <new-datadir> <socket-dir> <old-port> [pg_upgrade options...]"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 6 ] || { usage >&2; exit 2; }
old_bin=$1; new_bin=$2; old_data=$3; new_data=$4
sock=$5; old_port=$6; shift 6
user=${PGUSER:-postgres}; new_port=$((old_port + 1))
[ -e "$new_data" ] && { echo "refusing: $new_data exists" >&2; exit 2; }

checksums=$("$old_bin/pg_controldata" "$old_data" | awk -F: '/Data page checksum version/ {gsub(/ /,"",$2); print $2}')
q() { "$new_bin/psql" -X -At -h "$sock" -p "$old_port" -U "$user" -d template1 -c "$1"; }
encoding=$(q "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'template1'")
provider=$(q "SELECT datlocprovider FROM pg_database WHERE datname = 'template1'")
collate=$(q "SELECT datcollate FROM pg_database WHERE datname = 'template1'")
ctype=$(q "SELECT datctype FROM pg_database WHERE datname = 'template1'")
server_major=$(q "SHOW server_version_num"); server_major=$((server_major / 10000))
if [ "$server_major" -ge 17 ]; then
  locale=$(q "SELECT coalesce(datlocale, '') FROM pg_database WHERE datname = 'template1'")
else
  locale=$(q "SELECT coalesce(daticulocale, '') FROM pg_database WHERE datname = 'template1'")
fi

args=(-D "$new_data" -U "$user" --encoding="$encoding" --lc-collate="$collate" --lc-ctype="$ctype")
case "$provider" in
  b) args+=(--locale-provider=builtin --builtin-locale="$locale") ;;
  i) args+=(--locale-provider=icu --icu-locale="$locale") ;;
  *) args+=(--locale-provider=libc) ;;
esac
[ "$checksums" = "0" ] && args+=(--no-data-checksums)
echo "initdb ${args[*]}"
"$new_bin/initdb" "${args[@]}" >/dev/null

# Logical slots migrate only into a new cluster with wal_level = logical (old cluster 17 or later).
slots=$("$new_bin/psql" -X -At -h "$sock" -p "$old_port" -U "$user" -d postgres \
  -c "SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical'")
if [ "$slots" != "0" ]; then
  echo "wal_level = logical" >> "$new_data/postgresql.conf"
  echo "old cluster has $slots logical slot(s): set wal_level = logical in the new cluster"
  "$new_bin/psql" -X -At -h "$sock" -p "$old_port" -U "$user" -d postgres -c \
    "SELECT 'plugin not in the 18.6 default output_plugin_libraries: ' || plugin FROM pg_replication_slots
     WHERE slot_type = 'logical' AND plugin NOT IN ('pgoutput', 'test_decoding') GROUP BY plugin"
fi

work=$(mktemp -d)
cd "$work"
set +e
"$new_bin/pg_upgrade" -b "$old_bin" -B "$new_bin" -d "$old_data" -D "$new_data" -U "$user" \
  -p "$old_port" -P "$new_port" -s "$sock" --check "$@"
rc=$?
set -e
echo "pg_upgrade --check exit code: $rc (reports under $new_data/pg_upgrade_output.d when it failed)"
exit $rc
