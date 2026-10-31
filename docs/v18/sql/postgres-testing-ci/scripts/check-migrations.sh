#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# check-migrations.sh: apply every up migration, then prove each down + up returns the same schema.
# Usage: check-migrations.sh <migrations dir> <connection string to an EMPTY scratch database>
# Migrations are NNN_up.sql / NNN_down.sql pairs; needs psql and a pg_dump with --restrict-key (18, or 17.6, 16.10, 15.14, 14.19, 13.22 and later) on PATH.
set -euo pipefail
usage() { echo "usage: check-migrations.sh <migrations dir> <connection string to an EMPTY scratch database>"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -eq 2 ] || { usage >&2; exit 2; }
dir=$1; db=$2
psql_() { psql -d "$db" -X -v ON_ERROR_STOP=1 -q "$@"; }
dump() { pg_dump --schema-only --no-owner --no-privileges --restrict-key=schemadiff -d "$db"; }
work=$(mktemp -d); trap 'rm -rf -- "${work:?}"' EXIT

dump > "$work/empty.sql"
ups=$(ls "$dir"/*_up.sql | sort)
for up in $ups; do psql_ -f "$up"; done
dump > "$work/head.sql"

for up in $(echo "$ups" | sort -r); do
  down=${up%_up.sql}_down.sql
  psql_ -f "$down"
  dump > "$work/before.sql"
  psql_ -f "$up"; psql_ -f "$down"
  dump > "$work/after.sql"
  diff -u "$work/before.sql" "$work/after.sql" || { echo "FAIL: $(basename "$up") then its down does not restore the schema"; exit 1; }
done
diff -u "$work/empty.sql" "$work/before.sql" || { echo "FAIL: all downs do not return to the empty schema"; exit 1; }
for up in $ups; do psql_ -f "$up"; done
diff -u "$work/head.sql" <(dump) || { echo "FAIL: re-applying ups gives a different schema"; exit 1; }
echo "OK: $(echo "$ups" | wc -l | tr -d ' ') migrations go down and up cleanly"
