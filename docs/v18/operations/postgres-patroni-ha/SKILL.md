---
name: postgres-patroni-ha
description: 'Runs highly available PostgreSQL 18 with Patroni 4.1 and etcd: three-node layouts and quorum, the patroni.yml settings that matter (ttl, loop_wait, retry_timeout, maximum_lag_on_failover, synchronous and quorum mode, use_pg_rewind, failsafe_mode), routing clients with HAProxy health checks, vip-manager or libpq multi-host strings, patronictl switchover, failover, reinit, restart and pause, fencing and split brain, failover drills and major upgrades under Patroni. Use when building automatic failover on VMs or bare metal, writing patroni.yml, a failover did not happen or happened twice, or planning a switchover or upgrade.'
metadata:
  tags:
  - postgres
  - patroni
  - high-availability
  - failover
  - etcd
  - haproxy
  - split-brain
  - switchover
---

# PostgreSQL high availability with Patroni

Patroni runs next to each PostgreSQL server, holds a leader lock in a distributed configuration store (DCS) such as
etcd, and promotes a replica when the leader stops renewing that lock. Use it on VMs or bare metal; on Kubernetes use
an operator, and on a managed service use the provider's failover. Build three of everything that votes: three etcd
members (one per failure domain) and at least two PostgreSQL nodes, three if you run synchronous replication.
Measure failover in drills, not on paper. Streaming replication itself (slots, lag, synchronous commit levels) is in
`postgres-replication-ha`; the full configuration files are in [references/patroni-config.md](references/patroni-config.md).
Versions checked in October 2026: Patroni 4.1.5, etcd 3.7.3 (3.6.16 and 3.5.35 maintained), vip-manager 5.0.0.


## Step 0: read Patroni, etcd and the live configuration

Patroni settings and API words changed in version 4, and `bootstrap.dcs` in the file may differ from what the cluster
runs, so read the versions and the configuration held in the DCS. `patronictl version` and `show-config` come from
Patroni 4.1.5; `demo` is the cluster's scope.

```bash
patroni --version; patronictl version
etcdctl version; etcdctl endpoint status --cluster -w table
patronictl -c /etc/patroni/config.yml list demo
patronictl -c /etc/patroni/config.yml show-config demo        # the live settings, not the file's bootstrap section
psql -X -Atc 'SHOW server_version'
```

## How Patroni decides who is primary

Each Patroni node runs an HA loop every `loop_wait` seconds. The leader renews a key in the DCS with a time to live
of `ttl` seconds; replicas watch it. When the key expires, the healthiest replica (within `maximum_lag_on_failover`
bytes of the last known leader position, highest `failover_priority` on ties) takes the lock and promotes itself. A
leader that cannot renew the key demotes itself, so two primaries cannot both hold the lock. The REST API on each
node (port 8008 by default) answers health checks for load balancers and carries switchover requests.

## Three-node layouts and quorum

The DCS decides, so its quorum decides availability: an etcd cluster of n members needs a majority, (n/2)+1, and the
etcd FAQ recommends odd sizes. PostgreSQL nodes do not vote.

| Layout | Survives | Notes |
|---|---|---|
| 3 hosts, each PostgreSQL + etcd, three zones | one host or zone | the common layout |
| 2 PostgreSQL + 3 etcd (third etcd on a small witness host) | one host | cheapest; no synchronous standby left after one loss |
| 3 PostgreSQL + 5 etcd across three zones | two etcd members, one PostgreSQL | for strict uptime targets |
| 2 data centres only | not a data centre loss | the side without etcd majority cannot elect; put a witness in a third site |

Keep etcd on fast local disks and low-latency links: slow fsync or a congested network expires the leader key and
causes needless failovers.

## Installing Patroni and etcd

Patroni and its DCS run on Linux in production; the watchdog that fences a frozen leader is Linux-only. On macOS and
Windows, build labs in Linux containers.

| Platform | Install |
|---|---|
| Debian, Ubuntu (PGDG apt) | `apt-get install patroni python3-etcd etcd-server` |
| RHEL, Rocky, Alma (PGDG yum) | `dnf install patroni patroni-etcd` |
| pip | `pip install "patroni[psycopg3,etcd3]"` |

The Debian `patroni` package does not pull the etcd client library. Without `python3-etcd`, Patroni stops with
`Can not find suitable configuration of distributed configuration store` and lists only `consul, kubernetes`. Use the
`etcd3` section (the v3 API): etcd 3.6 no longer supports the `--enable-v2` flag. Debian ships the units
`patroni.service` (one cluster, `/etc/patroni/config.yml`, `Type=notify`) and `patroni@.service` (one per
`/etc/patroni/<instance>.yml`).

## The patroni.yml settings that matter

The `bootstrap.dcs` section is written to the DCS once, when the cluster is first initialised; later changes go
through `patronictl edit-config`, not the file. This core ran in our three-node lab on PostgreSQL 18.6:

```yaml
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: quorum
    synchronous_node_count: 1
    failsafe_mode: true
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: 10GB
  initdb:
    - data-checksums
```

| Setting | Default | What it decides |
|---|---|---|
| `ttl` | 30 (minimum 20) | seconds without a renewal before failover starts |
| `loop_wait` | 10 (minimum 1) | seconds between HA loop runs |
| `retry_timeout` | 10 (minimum 3) | DCS and PostgreSQL outages shorter than this do not demote the leader |
| `maximum_lag_on_failover` | 1048576 (1 MiB, shown by `show-config`) | replicas further behind may not take over |
| `use_pg_rewind` | false | rewind a failed leader instead of rebuilding it; needs checksums or `wal_log_hints` |
| `use_slots` | true | a physical slot per replica on the leader |
| `failsafe_mode` | false | keep the primary when the DCS is down but all members answer |

Keep `loop_wait + 2 * retry_timeout <= ttl`; the docs require it. PostgreSQL parameters that must match on all nodes
(`max_connections`, `max_wal_senders`, `max_worker_processes` and similar) belong in the DCS section, never in a
local `postgresql.conf`. `patroni --validate-config patroni.yml` checks a file before use; it rejects
`connect_address` values of `127.0.0.1` or `localhost` and DCS hosts it cannot reach.

## Synchronous mode and quorum commit

Patroni's `synchronous_mode` manages `synchronous_standby_names` itself and only lets a synchronous standby (or the
last leader) win an election, so no acknowledged commit is lost on automatic failover. With `synchronous_mode:
quorum` and `synchronous_node_count: 1`, our three-node lab ran `synchronous_standby_names = 'ANY 1 (node2,node3)'`.

| Mode | Lost commits on failover | Writes when standbys are gone |
|---|---|---|
| `off` (default) | up to `maximum_lag_on_failover` plus the last `ttl` seconds | continue |
| `on` | none for acknowledged commits | continue unprotected after Patroni drops sync |
| `quorum` | none; any quorum subset holds the latest commit | as `on` |
| add `synchronous_mode_strict: true` | none | block until a standby returns |

Transactions with `synchronous_commit = off` or `local` can still be lost. Use three PostgreSQL nodes with
synchronous replication so one standby can fail without blocking or dropping protection.

## Routing clients to the primary

Clients must find the new primary after a failover without a config change. Patroni's REST API gives load balancers
an HTTP answer per role:

| Endpoint | 200 when |
|---|---|
| `/primary`, `/read-write` | this node is the running leader |
| `/replica` | a running replica without the `noloadbalance` tag |
| `/replica?lag=10MB` | a replica no further behind than the limit |
| `/read-only` | the leader or a replica |
| `/health` | PostgreSQL is running |
| `/liveness`, `/readiness` | for Kubernetes probes |

HAProxy checks each node's REST port and sends traffic only to the node that answers 200; `on-marked-down
shutdown-sessions` cuts connections to a demoted node at once:

```
listen primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 10.0.1.11:5432 maxconn 500 check port 8008
    server pg2 10.0.2.11:5432 maxconn 500 check port 8008
    server pg3 10.0.3.11:5432 maxconn 500 check port 8008
```

Alternatives: vip-manager moves a virtual IP to the leader (Linux, same layer-2 network); libpq and most drivers
accept several hosts, `host=pg1,pg2,pg3 target_session_attrs=read-write`. Configurations for each:
[references/patroni-config.md](references/patroni-config.md).

## patronictl operations

`patronictl` reads the same YAML and talks to the DCS and the REST APIs. These commands ran against the lab:

```bash
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml switchover demo --leader node1 --candidate node2 --force
patronictl -c /etc/patroni/config.yml failover demo --candidate node3 --force     # when no healthy leader exists
patronictl -c /etc/patroni/config.yml reinit demo node3 --force --wait            # rebuild a broken replica
patronictl -c /etc/patroni/config.yml edit-config demo --set postgresql.parameters.max_connections=300 --force
patronictl -c /etc/patroni/config.yml restart demo --pending --force              # restart members marked "Pending restart"
patronictl -c /etc/patroni/config.yml pause demo --wait                           # maintenance mode: no automatic failover
patronictl -c /etc/patroni/config.yml resume demo --wait
patronictl -c /etc/patroni/config.yml history demo
```

- After `edit-config` of a restart-only parameter, `list` showed `Pending restart` with the reason
  `max_connections: 200->300`; `restart --pending` restarted the members in turn.
- `switchover --scheduled '2026-11-01T03:00+00:00'` schedules it; `flush demo switchover` cancels.
- Patroni 4 removed the word master: use `--leader` or `--primary`, and expect `primary` in API answers and callbacks.
- In `pause`, Patroni promotes no replica even when the primary is gone; resume before you walk away.

## Fencing and split brain

Split brain means two nodes accept writes. Patroni prevents it with the leader key: a leader that cannot renew it
within `ttl` demotes itself. That fails when the Patroni process is frozen (a paused VM, an overloaded host) while
PostgreSQL keeps serving.

- Watchdog: with `watchdog: {mode: required, device: /dev/watchdog}` a node refuses to lead unless a Linux watchdog
  (hardware or `softdog`) can reset it; by default it fires 5 seconds before the key expires.
- `failsafe_mode`: during a DCS outage the primary stays primary only while every member confirms it over the REST
  API. With two of three etcd members frozen for 45 seconds, our leader logged `continue to run as a leader because
  failsafe mode is enabled and all members are accessible`, and `/primary` kept answering 200.
- `pre_promote`: a script run after a node takes the lock and before promotion; a non-zero exit cancels the
  promotion. Use it to cut the old primary off (storage, cloud API, network).
- HAProxy with `on-marked-down shutdown-sessions` drops clients from a node the moment it stops being primary.

## Failover drills

A drill proves the timings and the client behaviour. Run [scripts/switchover-drill.sh](scripts/switchover-drill.sh)
for planned switchovers (its steps are inline under Verify), and an unplanned one by killing the leader in staging.

When the file is not on disk (a pack install), read this script from the library that served this page and save it first.

Results from our lab
(three nodes on one host, `ttl: 30`, `loop_wait: 10`):

| Drill | Result |
|---|---|
| planned switchover | new leader and every member streaming again after 5 to 6 s |
| `kill -9` of the leader's Patroni and postmaster | new leader after 22 s (31 s in an earlier run): failover takes up to `ttl` |
| restart of the killed node | Patroni ran `pg_rewind` (`servers diverged at WAL location ...`, `pg_rewind: Done!`) and it streamed again |
| `reinit` of a replica | finished with `--wait` |

Watch the application during the drill: connection errors, retries and how long writes fail. That number is your
real recovery time.

## Major upgrades under Patroni

Patroni does not run `pg_upgrade` for you. The Patroni documentation's procedure: stop Patroni on all nodes, run
`pg_upgrade` on the primary, update `bin_dir` and `data_dir` in each `patroni.yml`, remove the cluster state from the
DCS (`patronictl remove <cluster>`, because the new cluster has a new system identifier), start Patroni on the
primary, then wipe the replicas' data directories and let Patroni rebuild them. For less downtime, upgrade with
logical replication into a new Patroni cluster instead; both paths are in `postgres-zero-downtime-upgrades`.

## Verify a cluster with a timed switchover

This is the drill script by hand, for an install without script files. Keep a client writing in a loop while it runs,
because that client's errors are your real recovery time.

```bash
time patronictl -c /etc/patroni/config.yml switchover demo --leader node1 --candidate node2 --force
patronictl -c /etc/patroni/config.yml list demo               # node2 Leader, the others streaming
patronictl -c /etc/patroni/config.yml history demo | tail -3
curl -s -o /dev/null -w '%{http_code}\n' http://node2:8008/primary   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://node1:8008/primary   # anything but 200
```

Check the arithmetic too: `loop_wait + 2 * retry_timeout` must not pass `ttl` in `show-config`. The switchover, list
and history commands ran in the three-node lab described above.

## Gotchas

These are the failures seen most often with Patroni, each with its cause and fix.

1. **Failovers without a real outage.** etcd latency or a short network blip expired the key. Check etcd disk
   latency; raise `ttl` and `retry_timeout` together, keeping `loop_wait + 2 * retry_timeout <= ttl`.
2. **No failover when the primary died.** Every replica was further behind than `maximum_lag_on_failover`, or the
   cluster was paused. Check `list` for `Maintenance mode: on` and the replicas' lag.
3. **Patroni in a container hangs in `switchover: demote in progress`.** The container's PID 1 does not reap
   processes, so the stopped postmaster stays a zombie and Patroni waits for it. Run containers with an init
   (`docker run --init`, tini). We hit this in the lab.
4. **Writes block after a standby failure.** `synchronous_mode_strict` with no standby left. Restore a standby or
   turn strict mode off with `edit-config`.
5. **A setting in `postgresql.conf` is ignored or overwritten.** Patroni writes the configuration. Put cluster-wide
   parameters in the DCS with `edit-config`.
6. **The old leader cannot rejoin: `pg_rewind` refused.** Checksums and `wal_log_hints` were both off. Enable one
   (Patroni turns `wal_log_hints` on when `use_pg_rewind` is on; our lab showed it on), or `reinit` the node.

## Anti-patterns with Patroni

Each of these removes the protection you installed Patroni for.

| Do not | Do instead |
|---|---|
| Run etcd on two nodes, or all of it in one zone | Run three members in three failure domains |
| Edit `postgresql.conf` on a node | Change settings with `patronictl edit-config` |
| Restart Postgres with `pg_ctl` or systemd behind Patroni's back | Use `patronictl restart` |
| Leave the cluster paused after maintenance | Run `resume`: no replica is promoted while paused |
| Point clients at one host name you update by hand | Route with HAProxy checks, a VIP or multi-host strings |
| Trust a failover you never drilled | Time switchovers and hard kills with the application connected |

## Checklist

Check these points before you call a Patroni cluster production-ready.

- [ ] Three etcd members in three failure domains; Patroni uses the `etcd3` section.
- [ ] `loop_wait + 2 * retry_timeout <= ttl`; `maximum_lag_on_failover` matches your data-loss budget.
- [ ] `use_pg_rewind: true` with checksums; `use_slots: true` with `max_slot_wal_keep_size`.
- [ ] Clients reach the primary through HAProxy `/primary` checks, a VIP or multi-host strings.
- [ ] A watchdog or `pre_promote` fencing is in place, and containers run with an init process.
- [ ] Switchover and hard-failure drills have been run and timed, with the application connected.

## See also

Related skills in this library, each one works on its own:

- `postgres-replication-ha`: streaming replication, slots and lag.
- `postgres-kubernetes`: operators instead of Patroni on Kubernetes.
- `postgres-connection-pooling`: PgBouncer behind HAProxy.
- `postgres-zero-downtime-upgrades`: major upgrades without downtime.
- `postgres-os-kernel-tuning`: watchdog hosts and kernel settings.

## Sources

- https://patroni.readthedocs.io/en/latest/dynamic_configuration.html
- https://patroni.readthedocs.io/en/latest/yaml_configuration.html
- https://patroni.readthedocs.io/en/latest/replication_modes.html
- https://patroni.readthedocs.io/en/latest/rest_api.html
- https://patroni.readthedocs.io/en/latest/patronictl.html
- https://patroni.readthedocs.io/en/latest/watchdog.html
- https://patroni.readthedocs.io/en/latest/existing_data.html (major upgrade)
- https://patroni.readthedocs.io/en/latest/releases.html (4.0.0, 4.1.0)
- https://etcd.io/docs/v3.6/faq/ and https://etcd.io/docs/v3.6/upgrades/upgrade_3_6/
- https://github.com/haproxy/haproxy/blob/master/doc/configuration.txt (`option httpchk`, `on-marked-down`)
