#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# Apply one migration file to every tenant schema, once, resumable.
# Usage: migrate-schemas.sh <migration.sql> <version> [schema LIKE pattern, default tenant\_%]
# Connection comes from the usual libpq variables (PGHOST, PGPORT, PGDATABASE, PGUSER) or a service file.
# Each schema gets its own transaction with lock_timeout, the file runs with search_path set to that schema,
# and <schema>.schema_migrations records the version so a rerun skips finished schemas.
set -euo pipefail
usage() { echo "usage: migrate-schemas.sh <migration.sql> <version> [schema LIKE pattern, default tenant\\_%]"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 2 ] || { usage >&2; exit 2; }
file=$1; version=$2; pattern=${3:-tenant\\_%}
[ -r "$file" ] || { echo "cannot read $file" >&2; exit 2; }
psql_q() { psql -X -v ON_ERROR_STOP=1 -At "$@"; }
schemas=$(psql_q -v pattern="$pattern" <<'SQL'
SELECT quote_ident(nspname) FROM pg_namespace WHERE nspname LIKE :'pattern' ORDER BY nspname;
SQL
)
done_count=0; skip_count=0; fail_count=0
for s in $schemas; do
  has_table=$(psql_q -v s="$s" <<'SQL'
SELECT to_regclass(:'s' || '.schema_migrations') IS NOT NULL;
SQL
)
  if [ "$has_table" = "t" ]; then
    applied=$(psql_q -v v="$version" <<SQL
SELECT count(*) FROM $s.schema_migrations WHERE version = :'v';
SQL
)
    [ "$applied" != "0" ] && { skip_count=$((skip_count + 1)); continue; }
  fi
  if { printf 'BEGIN;\nSET LOCAL lock_timeout = %s;\nSET LOCAL search_path = %s;\n' "'5s'" "$s"
       printf 'CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());\n'
       cat "$file"
       printf '\nINSERT INTO schema_migrations (version) VALUES (%s);\nCOMMIT;\n' "'$version'"
     } | psql -X -v ON_ERROR_STOP=1 -q >/dev/null; then
    done_count=$((done_count + 1))
  else
    fail_count=$((fail_count + 1)); echo "FAILED: $s (rerun to retry)" >&2
  fi
done
echo "applied=$done_count skipped=$skip_count failed=$fail_count"
[ "$fail_count" -eq 0 ]
