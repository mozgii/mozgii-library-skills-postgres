#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# Restore drill for a logical backup: restores a pg_dump custom or directory archive into a scratch database,
# runs a check query, prints the duration, and drops the scratch database.
#
# Usage: restore-drill.sh <dump file or directory> "<check SQL returning one value>" [expected value]
# Connection: standard libpq settings (PGHOST, PGPORT, PGUSER, ~/.pgpass); the user needs CREATEDB.
# Example: PGHOST=drill.internal ./restore-drill.sh app.dump "SELECT count(*) > 0 FROM app.orders" t
set -euo pipefail

usage='Usage: restore-drill.sh <dump file or directory> "<check SQL returning one value>" [expected value]'
case "${1:-}" in
  -h|--help) echo "$usage"; exit 0 ;;
  '') echo "$usage" >&2; exit 2 ;;
esac

dump=$1
check_sql=${2:?check SQL}
expected=${3:-}
scratch="drill_$(date +%s)_$$"
jobs=${DRILL_JOBS:-4}

cleanup() { dropdb --if-exists "$scratch" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start=$(date +%s)
createdb "$scratch"
pg_restore --no-owner --no-privileges --exit-on-error -j "$jobs" -d "$scratch" "$dump"
vacuumdb --analyze-only -d "$scratch" >/dev/null
result=$(psql -X -At -v ON_ERROR_STOP=1 -d "$scratch" -c "$check_sql")
seconds=$(( $(date +%s) - start ))

if [[ -n "$expected" && "$result" != "$expected" ]]; then
  echo "FAIL dump=$dump result=$result expected=$expected seconds=$seconds"
  exit 1
fi
echo "PASS dump=$dump result=$result seconds=$seconds"
