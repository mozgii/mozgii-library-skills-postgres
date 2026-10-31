---
title: Patroni configuration files for a three-node cluster
author: MOZGII, Inc.
lang: en
---

# Patroni configuration files for a three-node cluster

This reference holds complete, annotated configuration for a three-node PostgreSQL 18 cluster with Patroni 4.1 and
etcd: the etcd members, `patroni.yml`, HAProxy, vip-manager, client connection strings and the systemd units. The
`patroni.yml` and HAProxy file were checked (`patroni --validate-config`, `haproxy -c`); the Patroni settings ran in
a lab cluster on PostgreSQL 18.6.

## etcd members

Each of the three hosts runs one etcd member, and the initial cluster list is the same on all three. In production
add TLS between members and for clients (`--cert-file`, `--key-file`, `--trusted-ca-file`, `--client-cert-auth`,
and the `--peer-*` equivalents). These commands start the member on pg1 and check the cluster:

```bash
# on pg1 (10.0.1.11); change --name and the addresses on pg2 and pg3
etcd --name pg1 --data-dir /var/lib/etcd \
  --listen-client-urls http://10.0.1.11:2379 --advertise-client-urls http://10.0.1.11:2379 \
  --listen-peer-urls http://10.0.1.11:2380 --initial-advertise-peer-urls http://10.0.1.11:2380 \
  --initial-cluster pg1=http://10.0.1.11:2380,pg2=http://10.0.2.11:2380,pg3=http://10.0.3.11:2380 \
  --initial-cluster-state new --initial-cluster-token pg-prod
etcdctl --endpoints=10.0.1.11:2379,10.0.2.11:2379,10.0.3.11:2379 endpoint health
```

`endpoint health` should report all three members healthy before Patroni starts. Back up etcd (`etcdctl snapshot
save`) like any other critical service; Patroni can rebuild its keys, but not without the cluster being reachable.

## patroni.yml for one node

Each node has the same file except `name`, `restapi` and `postgresql` addresses. Passwords here are placeholders:
load real ones from a secret store into the file at deploy time, or set them through Patroni's environment
variables (`PATRONI_SUPERUSER_PASSWORD`, `PATRONI_REPLICATION_PASSWORD`). The file for pg1:

```yaml
scope: pg-prod                 # cluster name, the same on every node
namespace: /service/
name: pg1                      # unique per node

restapi:
  listen: 10.0.1.11:8008
  connect_address: 10.0.1.11:8008
  # certfile / keyfile / authentication for TLS and basic auth on the REST API

etcd3:
  hosts: 10.0.1.11:2379,10.0.2.11:2379,10.0.3.11:2379

bootstrap:
  dcs:                         # written to the DCS once; change later with patronictl edit-config
    ttl: 30
    loop_wait: 10
    retry_timeout: 10          # loop_wait + 2 * retry_timeout <= ttl
    maximum_lag_on_failover: 1048576
    synchronous_mode: quorum
    synchronous_node_count: 1
    failsafe_mode: true
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: 10GB
        wal_keep_size: 1GB
        password_encryption: scram-sha-256
        ssl: 'on'                      # both hostssl lines below match nothing without it
        ssl_cert_file: /etc/patroni/tls/server.crt
        ssl_key_file: /etc/patroni/tls/server.key
  initdb:
    - encoding: UTF8
    - locale-provider: builtin
    - builtin-locale: C.UTF-8
    - data-checksums

postgresql:
  listen: 10.0.1.11:5432
  connect_address: 10.0.1.11:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin
  pgpass: /var/lib/postgresql/.pgpass_patroni
  authentication:
    superuser:   {username: postgres,    password: '<from secret store>'}
    replication: {username: replicator,  password: '<from secret store>'}
    rewind:      {username: rewind_user, password: '<from secret store>'}
  pg_hba:
    - local all all peer
    - hostssl replication replicator 10.0.0.0/16 scram-sha-256
    - hostssl all all 10.0.0.0/16 scram-sha-256        # needs ssl: 'on' and a certificate on every node

watchdog:
  mode: automatic              # required: refuse to lead without a working /dev/watchdog
  device: /dev/watchdog
  safety_margin: 5

tags:
  failover_priority: 1         # 0 = never fail over to this node; do not combine with nofailover
  noloadbalance: false
  clonefrom: false
  nosync: false
```

Check it before starting: `patroni --validate-config /etc/patroni/config.yml`. In the lab it rejected
`connect_address` values containing `127.0.0.1` and an etcd host that was not yet reachable. The `initdb` list above
created the lab cluster with the builtin `C.UTF-8` locale and data checksums.

## The Linux watchdog

The watchdog resets a node whose Patroni stopped running while it held the leader key. Load the software watchdog if
the host has no hardware one, and give the Patroni user access:

```bash
modprobe softdog
chown postgres /dev/watchdog
```

Make both persistent (a modules-load entry and a udev rule). For tests, `modprobe softdog soft_noboot=1` logs instead
of rebooting. Watchdog support exists only on Linux.

## HAProxy in front of the cluster

HAProxy sends writes to the node whose `/primary` check answers 200 and reads to healthy replicas. Run two HAProxy
instances (with a VIP or DNS in front) so the proxy is not a single point of failure. This file passed `haproxy -c`
on HAProxy 3.4.7:

```
global
    maxconn 4000

defaults
    mode tcp
    log global
    retries 2
    timeout connect 4s
    timeout client 30m
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 10.0.1.11:5432 maxconn 500 check port 8008
    server pg2 10.0.2.11:5432 maxconn 500 check port 8008
    server pg3 10.0.3.11:5432 maxconn 500 check port 8008

listen replicas
    bind *:5001
    balance roundrobin
    option httpchk GET /replica?lag=10MB
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 10.0.1.11:5432 maxconn 500 check port 8008
    server pg2 10.0.2.11:5432 maxconn 500 check port 8008
    server pg3 10.0.3.11:5432 maxconn 500 check port 8008
```

With `failsafe_mode`, the leader kept answering 200 on `/primary` and `/leader` while the DCS had lost quorum in our
lab, so HAProxy kept routing writes to it.

## vip-manager for a floating IP

vip-manager adds a virtual IP to the network interface of the node that holds the leader key, so clients use one
address. It works on Linux hosts in one layer-2 network (or with the Hetzner API). Version 5.0.0 changed its
configuration and now removes the VIP when it cannot reach the DCS; with `failsafe_mode`, point it at Patroni's REST
API instead of etcd so an etcd outage does not drop the address of a primary that is still serving. Keys follow the
vip-manager README:

```yaml
# /etc/default/vip-manager.yml on pg1
ip: 10.0.1.100
netmask: 24
interface: eth0
manager-type: basic
dcs-type: patroni
dcs-endpoints: http://127.0.0.1:8008
trigger-key: /leader
trigger-value: 200
interval: 1000
```

With `dcs-type: etcd`, use `trigger-key: /service/pg-prod/leader` (`<namespace><scope>/leader`) and
`trigger-value: pg1` (the node's Patroni `name`). This file was checked against the README's key table, not run.

## Client connection strings

libpq and drivers built on it can try several hosts and keep only a writable one, which removes the proxy from the
write path:

```
postgresql://app@pg1:5432,pg2:5432,pg3:5432/app?target_session_attrs=read-write&connect_timeout=3
postgresql://app@pg1:5432,pg2:5432,pg3:5432/app?target_session_attrs=prefer-standby&load_balance_hosts=random
```

The first finds the primary after a failover on reconnect; the second spreads reads over standbys.
`load_balance_hosts` needs libpq 16 or later. Drivers that do not use libpq (JDBC, Npgsql, node-postgres) have their
own multi-host options (`postgres-app-drivers`).

## systemd units

The Debian and Ubuntu `patroni` package installs `patroni.service` for one cluster per host and `patroni@.service`
for several. The single-cluster unit, as shipped:

```ini
[Unit]
Description=Runners to orchestrate a high-availability PostgreSQL
After=network.target
ConditionPathExists=/etc/patroni/config.yml

[Service]
Type=notify
User=postgres
Group=postgres
EnvironmentFile=-/etc/patroni_env.conf
ExecStart=/usr/bin/patroni /etc/patroni/config.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`KillMode=process` stops only Patroni when the service stops, so PostgreSQL is shut down by Patroni and not killed
by systemd. Disable the distribution's own `postgresql` service on Patroni nodes, or two managers fight over one data
directory. `Type=notify` needs Patroni 4.1 or later; a pip install also needs the `systemd` extra (`patroni[systemd]`).

## Sources

- https://patroni.readthedocs.io/en/latest/yaml_configuration.html
- https://patroni.readthedocs.io/en/latest/ENVIRONMENT.html
- https://patroni.readthedocs.io/en/latest/watchdog.html
- https://patroni.readthedocs.io/en/latest/rest_api.html
- https://github.com/patroni/patroni/blob/master/haproxy.cfg
- https://github.com/cybertec-postgresql/vip-manager (README, release v5.0.0)
- https://etcd.io/docs/v3.6/op-guide/clustering/
- https://www.postgresql.org/docs/18/libpq-connect.html (`target_session_attrs`, `load_balance_hosts`)
