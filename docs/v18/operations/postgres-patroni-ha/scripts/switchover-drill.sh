#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# Planned switchover drill for a Patroni cluster: switch to a candidate, time it, wait until every member is back.
# Usage: switchover-drill.sh <patroni.yml> <cluster-name> <candidate-member> [timeout-seconds, default 120]
# Run on a Patroni node (or any host with patronictl and the same DCS settings). Needs python3 for JSON parsing.
set -euo pipefail
usage() { echo "usage: switchover-drill.sh <patroni.yml> <cluster-name> <candidate-member> [timeout-seconds, default 120]"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 3 ] || { usage >&2; exit 2; }
cfg=$1; cluster=$2; candidate=$3; timeout=${4:-120}
ctl() { patronictl -c "$cfg" "$@"; }
state() {   # prints: leader-name <members not yet running/streaming>
  ctl list "$cluster" -f json | python3 -c '
import json, sys
m = json.load(sys.stdin)
leader = [x["Member"] for x in m if x["Role"] == "Leader"]
pending = [x["Member"] for x in m if x["State"] not in ("running", "streaming")]
print((leader or ["none"])[0], len(pending))'
}
read -r leader pending < <(state)
[ "$leader" = "$candidate" ] && { echo "$candidate is already the leader" >&2; exit 2; }
echo "before: leader=$leader"; ctl list "$cluster"
start=$(date +%s)
ctl switchover "$cluster" --leader "$leader" --candidate "$candidate" --force
while :; do
  read -r now_leader pending < <(state)
  [ "$now_leader" = "$candidate" ] && [ "$pending" = "0" ] && break
  [ $(( $(date +%s) - start )) -ge "$timeout" ] && { echo "TIMEOUT: leader=$now_leader pending=$pending" >&2; ctl list "$cluster"; exit 1; }
  sleep 1
done
echo "after: leader=$candidate, all members running or streaming after $(( $(date +%s) - start ))s"
ctl list "$cluster"
ctl history "$cluster" | tail -3
