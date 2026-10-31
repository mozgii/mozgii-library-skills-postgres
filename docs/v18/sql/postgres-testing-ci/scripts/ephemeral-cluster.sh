#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# ephemeral-cluster.sh: run one command against a throwaway PostgreSQL cluster, then stop and delete it.
# Usage: PG_BIN=/usr/lib/postgresql/18/bin ephemeral-cluster.sh <command> [args...]
# The command gets DATABASE_URL (Unix socket, user postgres, database postgres).
# PG_TEST_PORT picks the port (default 54329); PG_TEST_KEEP=1 keeps the cluster files for inspection.
# macOS and Linux. On Windows run it in WSL, or use a container.
set -euo pipefail

usage() { echo "usage: PG_BIN=/usr/lib/postgresql/18/bin ephemeral-cluster.sh <command> [args...]"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 1 ] || { usage >&2; exit 2; }

bin=${PG_BIN:-}
[ -n "$bin" ] || bin=$(dirname "$(command -v pg_ctl)")
root=$(mktemp -d "${TMPDIR:-/tmp}/pgtest.XXXXXX")
sock=$(mktemp -d /tmp/pgs.XXXXXX)          # short path: a socket path is limited to about 100 bytes
port=${PG_TEST_PORT:-54329}

cleanup() {
  "$bin/pg_ctl" stop -D "$root/data" -m immediate >/dev/null 2>&1 || :
  if [ "${PG_TEST_KEEP:-0}" = 1 ]; then
    echo "kept: $root $sock" >&2
  else
    rm -rf -- "${root:?}" "${sock:?}"
  fi
}
trap cleanup EXIT

"$bin/initdb" -D "$root/data" -U postgres --auth=trust --encoding=UTF8 \
  --locale-provider=builtin --builtin-locale=C.UTF-8 >"$root/initdb.log"

# Durability off: safe only because the cluster is thrown away after the run.
"$bin/pg_ctl" -D "$root/data" -l "$root/server.log" -w -o \
  "-c listen_addresses='' -k $sock -p $port -c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
  start >/dev/null

export DATABASE_URL="postgresql://postgres@/postgres?host=$sock&port=$port"
"$@"
