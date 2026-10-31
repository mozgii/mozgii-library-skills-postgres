#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# linux-host-check.sh: read-only report of the Linux settings that matter to PostgreSQL. Changes nothing.
# Usage: bash linux-host-check.sh [data_directory]
# Run it as the user that runs PostgreSQL (for ulimit) or as root (for everything else).
set -u
usage() { echo "usage: bash linux-host-check.sh [data_directory]"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
DATA_DIR="${1:-}"

read_file() { if [ -r "$1" ]; then tr -d '\n' < "$1"; else printf 'n/a'; fi; }
row() { printf '%-38s %s\n' "$1" "$2"; }

[ "$(uname -s)" = "Linux" ] || { echo "This report is for Linux only."; exit 1; }

echo "== kernel"
row "kernel release" "$(uname -r)"
row "CPUs online" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo n/a)"
row "memory total" "$(awk '/^MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
row "NUMA nodes" "$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l | tr -d ' ')"

echo "== virtual memory (sysctl vm.*)"
for k in overcommit_memory overcommit_ratio swappiness dirty_ratio dirty_background_ratio dirty_bytes \
         dirty_background_bytes zone_reclaim_mode nr_hugepages hugetlb_shm_group; do
  row "vm.$k" "$(read_file /proc/sys/vm/$k)"
done
row "swap total" "$(awk '/^SwapTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"

echo "== huge pages"
row "Hugepagesize" "$(awk '/^Hugepagesize/ {print $2" "$3}' /proc/meminfo)"
row "HugePages_Total / Free / Rsvd" "$(awk '/^HugePages_(Total|Free|Rsvd)/ {printf "%s ", $2}' /proc/meminfo)"
row "transparent_hugepage/enabled" "$(read_file /sys/kernel/mm/transparent_hugepage/enabled)"
row "transparent_hugepage/defrag" "$(read_file /sys/kernel/mm/transparent_hugepage/defrag)"

echo "== io_uring"
row "kernel.io_uring_disabled" "$(read_file /proc/sys/kernel/io_uring_disabled)"

echo "== limits of this shell"
row "ulimit -n (open files)" "$(ulimit -n)"
row "ulimit -u (processes)" "$(ulimit -u)"
row "ulimit -l (locked memory, KiB)" "$(ulimit -l)"
row "fs.file-max" "$(read_file /proc/sys/fs/file-max)"

echo "== block devices: scheduler, rotational, read-ahead (KiB)"
for q in /sys/block/*/queue; do
  dev=$(basename "$(dirname "$q")")
  case "$dev" in loop*|ram*|zram*) continue ;; esac
  row "$dev" "sched=$(read_file "$q/scheduler") rotational=$(read_file "$q/rotational") read_ahead_kb=$(read_file "$q/read_ahead_kb")"
done

if [ -n "$DATA_DIR" ]; then
  echo "== file system holding $DATA_DIR"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -no SOURCE,FSTYPE,OPTIONS --target "$DATA_DIR"
  else
    df -P "$DATA_DIR" | tail -1
  fi
fi

echo "== systemd (if present)"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  for u in $(systemctl list-units --type=service --no-legend 'postgresql*' 2>/dev/null | awk '{print $1}'); do
    row "$u" "$(systemctl show "$u" -p OOMScoreAdjust -p LimitNOFILE -p LimitMEMLOCK -p TimeoutStartUSec 2>/dev/null | tr '\n' ' ')"
  done
  row "logind RemoveIPC" "$(grep -hE '^\s*RemoveIPC' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null | tail -1 || true)"
else
  echo "systemd not running here"
fi
