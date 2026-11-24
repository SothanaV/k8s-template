# PostgreSQL 18 HA (repmgr + pgcat) — self-contained chart

Three PostgreSQL 18 nodes managed by [repmgr](https://repmgr.org/) with automatic
failover, fronted by [pgcat](https://github.com/postgresml/pgcat) for connection pooling
and read/write splitting. Kubernetes port of
[`docker-template/postgresql/postgresql-ha`](https://github.com/SothanaV/docker-template):
same cluster logic, same scripts, one endpoint for clients, and no ReadWriteMany volume
anywhere.

For the single-instance alternative in this repository see
[`../custom/README.md`](../custom/README.md).

## Table of Contents

- [Architecture](#architecture)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [Build the database image](#build-the-database-image)
- [Credentials](#credentials)
- [Installation](#installation)
- [Values Reference](#values-reference)
- [Connecting](#connecting)
- [How the write endpoint follows the primary](#how-the-write-endpoint-follows-the-primary)
- [Failover drill](#failover-drill)
- [Verifying the cluster](#verifying-the-cluster)
- [RBAC](#rbac)
- [Security](#security)
- [Scaling and replacing nodes](#scaling-and-replacing-nodes)
- [Rotating the passwords](#rotating-the-passwords)
- [Upgrading the chart](#upgrading-the-chart)
- [Troubleshooting](#troubleshooting)
- [Differences from the compose stack](#differences-from-the-compose-stack)
- [References](#references)

---

## Architecture

```
clients ──► pgcat.<ns>.svc:6432            (pgcat Deployment, read/write split)
              │  reads  ──► pg-ha-1, pg-ha-2   (streaming standbys)
              │  writes ──► the node repmgr says is primary
              │
              │  reads pgcat.toml from an emptyDir written by ──► config-watcher (sidecar)
              │                                                        │ GET every 3s
   pg-ha-0 ───┼── repmgrd ── promote_command ──┐                       ▼
   pg-ha-1 ───┼── repmgrd                      └─► pgcat-role-sync.sh  ConfigMap pgcat-config
   pg-ha-2 ───┘   (one StatefulSet, headless Service for stable DNS)         │ PATCH (RBAC)
                                                        primary node only ───┘
```

| Piece | What it is |
| ----- | ---------- |
| `pg-ha` StatefulSet | 3 pods, one RWO volume each, ordinal 0 bootstraps as the initial primary |
| `pg-ha-headless` Service | Governing Service; creates `pg-ha-<n>.pg-ha-headless.<ns>.svc` records, publishes Not-Ready pods too |
| `pgcat` Deployment | The client endpoint: transaction pooling, query-parser read/write splitting, Prometheus exporter on 9930 |
| `config-watcher` sidecar | Same pod as pgcat: GETs the published ConfigMap, fills in the passwords, writes `/config/pgcat.toml`, sends `RELOAD` |
| `pgcat-role-sync.sh` | Runs in the database pods: finds the real primary with `pg_is_in_recovery()` and PATCHes the ConfigMap |
| `pg-ha-conf` ConfigMap | Chart inputs mounted at `/templates`: `pgcat.toml.tpl`, `postgresql-append.conf`, `repmgr-extra.conf` |
| `pgcat-config` ConfigMap | Runtime state, written by the cluster, read by the sidecar. Holds no credentials |

Two ideas carry the design:

1. **Only PostgreSQL decides who is primary.** repmgrd promotes, and the entrypoint's
   `promote_command` re-runs the sync. Kubernetes readiness never routes a write.
2. **The Kubernetes API is the shared medium** that replaces the compose stack's shared
   `pgcat_conf` volume, so each node keeps a plain ReadWriteOnce volume.

There is deliberately **no ClusterIP Service in front of the database pods**: a plain
Service round-robins across standbys, and a write that lands on one fails with
`cannot execute ... in a read-only transaction`. Reach a node by pod DNS when you must.

---

## Files

| File | Purpose |
| ---- | ------- |
| `Chart.yaml` | Chart metadata; `appVersion` is the PostgreSQL major the image is built on |
| `values.yaml` | Default values; the image is published, `<STORAGE_CLASS>` is a placeholder |
| `image/Dockerfile` | `postgres:18-bookworm` + `postgresql-18-repmgr` + `as-postgres` + curl + jq + the scripts |
| `image/entrypoint.sh` | Node bootstrap: repmgr.conf, initdb/clone/rejoin, repmgrd supervisor, split-brain guard |
| `image/pgcat-role-sync.sh` | Finds the primary, renders the template, PATCHes the ConfigMap |
| `image/pgcat-config-watch.sh` | pgcat sidecar: GET, substitute secrets, atomic write, `RELOAD` |
| `files/pgcat.toml.tpl` | pgcat config template with the tokens the two scripts fill in |
| `templates/statefulset.yaml` | Database pods: env contract, probes, mounts, `volumeClaimTemplates` |
| `templates/deployment-pgcat.yaml` | pgcat + config-watcher sharing one emptyDir |
| `templates/service-headless.yaml` | Governing Service, per-pod DNS |
| `templates/service-pgcat.yaml` | Client endpoint (6432) and metrics port |
| `templates/configmap-conf.yaml` | `/templates` inputs |
| `templates/configmap-pgcat-config.yaml` | The live pgcat config key (`lookup` keeps it across upgrades) |
| `templates/rbac.yaml` | Two Roles + bindings: `get`/`patch` for the database pods, `get` only for the pooler, both on that one ConfigMap |
| `templates/serviceaccount.yaml` | The two identities: `pg-ha` (publisher) and `pgcat` (reader) |
| `templates/servicemonitor.yaml` | Optional pgcat exporter scrape |
| `templates/prometheusrule.yaml` | Optional alerts (kube-state-metrics + `up`) |
| `templates/_helpers.tpl` | Naming, FQDN derivation, config rendering, validation |
| `templates/NOTES.txt` | Post-install instructions |

Single chart, no dependencies, no subcharts: `helm dependency build` is never needed.

---

## Prerequisites

- Kubernetes 1.21+ (`persistentVolumeClaimRetentionPolicy`), Helm 3+
- A ReadWriteOnce StorageClass — **not** ReadWriteMany, that is the point of the ConfigMap
  plumbing. Check first:

```bash
kubectl get storageclass
```

- At least 3 schedulable nodes if you want the anti-affinity to be meaningful (it is
  `preferred`, so a smaller cluster still schedules)
- The database image, pullable from your nodes. The default `sothanav/pg-ha:18-repmgr` is on
  Docker Hub; [build your own](#build-the-database-image) if the cluster is air-gapped or you
  need to audit the layers
- The namespace and the [credentials Secret](#credentials), created before the install
- The node must let a process signal its own container. That sounds like nothing to check, but a
  container AppArmor profile with no `signal` rules (containerd 2.x applies its generated
  `cri-containerd.apparmor.d` by default on AppArmor 4 nodes) makes PostgreSQL accept no
  connection at all, silently. One command tells you, and
  [AppArmor](#apparmor-a-node-profile-that-refuses-signal-kills-postgres-silently) covers the fix:

  ```bash
  kubectl run aa-check --rm -it --restart=Never --image=alpine:3.20 --command -- \
    cat /proc/1/attr/current
  # unconfined                                              -> nothing to do
  # cri-containerd.apparmor.d//&unconfined (enforce)        -> read the section
  ```

- `metrics.enabled` needs the `monitoring.coreos.com` CRDs (kube-prometheus-stack)

> **Warning**: `values.yaml` ships `persistence.storageClass: "<STORAGE_CLASS>"` on purpose
> and Helm refuses to render it. A PVC with a missing StorageClass installs "successfully"
> and sits in `Pending`, which is the slow way to find out you edited the wrong file. The
> same rule still applies to `image.repository`: set it to a path that was never pushed
> (`<REGISTRY>/pg-ha`) and the render refuses it too.

---

## Build the database image

**Optional.** The chart's default, `sothanav/pg-ha:18-repmgr`, is this exact `image/`
directory published to Docker Hub, so nothing here is required to install. Build your own
when you need to audit or mirror the image, or when the nodes cannot reach Docker Hub —
repmgr is an apt package, so the image is a thin layer over `postgres:18-bookworm` and is
quick to reproduce:

```bash
docker build -t registry.local:5000/pg-ha:18-repmgr postgresql/sothanav-ha-pg/image
docker push registry.local:5000/pg-ha:18-repmgr
```

Then point the chart at it (the registry prefix stays empty when `repository` already
carries the host):

```yaml
# values.local.yaml
image:
  registry: ""
  repository: registry.local:5000/pg-ha
  tag: "18-repmgr"
```

To make an install reproducible regardless of who publishes the tag, pin the digest you
verified instead — `image.digest` replaces the tag in the rendered reference:

```bash
docker buildx build --push -t sothanav/pg-ha:18-repmgr postgresql/sothanav-ha-pg/image
docker buildx imagetools inspect sothanav/pg-ha:18-repmgr    # copy the Digest: line
```

```yaml
image:
  digest: "sha256:<that digest>"
```

What the image adds over `postgres:18-bookworm`: `postgresql-18-repmgr` (repmgr 5.5 +
`pg_rewind` from the matching major), `as-postgres` (the root → uid 999 step-down, also
installed at `/usr/local/bin/gosu` in place of the base image's gosu, which cannot signal its
own child on a node whose AppArmor profile refuses `signal` — see
[`image/README.md`](image/README.md)), `curl` + `jq` (the two scripts that talk to the API),
and the three scripts themselves in `/usr/local/bin`.

> **Warning**: `image.tag`, `repmgr.pgBindir`, and `postgresql-<major>-repmgr` in
> `image/Dockerfile` must agree on the major version. repmgr shells out to
> `pg_ctl`/`pg_rewind` from `pg_bindir`, and a mismatch shows up as a rejoin that cannot
> rewind a demoted node. The render fails when `image.tag` and `repmgr.pgBindir` disagree.

---

## Credentials

Three passwords, one Secret, created out of band. The chart never renders a credential
into a manifest: pods read only the keys they need through `secretKeyRef`.

```bash
kubectl -n <namespace> create secret generic pg-ha-secret \
  --from-literal=postgres-password="<POSTGRES_SUPERUSER_PASSWORD>" \
  --from-literal=repmgr-password="<REPMGR_REPLICATION_PASSWORD>" \
  --from-literal=pgcat-admin-password="<PGCAT_LOCAL_ADMIN_PASSWORD>"
```

| Key | Used by | Why |
| --- | ------- | --- |
| `postgres-password` | database pods, pgcat sidecar | `initdb` superuser; the credential pgcat uses for its pools |
| `repmgr-password` | database pods | replication, monitoring, and the `repmgr` role in `pg_hba.conf` |
| `pgcat-admin-password` | pgcat sidecar only | pgcat's local admin console (not a PostgreSQL role) |

> **Warning**: passwords must be printable ASCII without newlines or other control
> characters. They are substituted into a TOML file; `\` and `"` are escaped, a newline
> cannot be. Avoid `'` as well: the repmgr `conninfo` line is single-quoted, so an apostrophe
> would break `repmgr.conf`. Any of the three also makes the `psql` and shell commands you
> type by hand during an incident harder to get right — which is exactly when you type them.

The published ConfigMap holds no credential: `pgcat-role-sync.sh` leaves the password
tokens intact and the sidecar inside the pgcat pod substitutes them from its own Secret
keys. Anyone with read access to ConfigMaps in the namespace sees server hostnames, not
passwords.

---

## Installation

Run from the repository root so the `-f` paths resolve. Keep the real StorageClass (and your
own image path, if you built one) in `values.local.yaml` (gitignored, never committed). The
only value you must supply is the StorageClass — everything else has a usable default,
including `auth.existingSecret: pg-ha-secret`, which is the name [the Credentials
section](#credentials) creates the Secret under:

```yaml
# postgresql/sothanav-ha-pg/values.local.yaml
persistence:
  storageClass: <STORAGE_CLASS>        # kubectl get storageclass
```

### 1. Preview

```bash
helm template pg-ha postgresql/sothanav-ha-pg \
  -n database \
  -f postgresql/sothanav-ha-pg/values.local.yaml
```

### 2. Install

```bash
helm install pg-ha postgresql/sothanav-ha-pg \
  -n database --create-namespace \
  -f postgresql/sothanav-ha-pg/values.local.yaml
```

### 3. Watch the bootstrap

`podManagementPolicy: OrderedReady` starts the pods one at a time: ordinal 0 runs `initdb`
and registers as primary, becomes Ready, and only then is ordinal 1 created so its
`standby clone` has something to clone from.

```bash
kubectl -n database rollout status statefulset/pg-ha --timeout=15m
kubectl -n database logs pg-ha-0 -f          # repmgrd + PostgreSQL log in one stream
kubectl -n database get pods -w
```

Expect a few minutes on a cold volume; a standby cloning an existing database is bounded
by size and volume speed (`probes.startup` tolerates 30 minutes by default).

### 4. Verify

```bash
kubectl -n database exec pg-ha-0 -- as-postgres \
  repmgr -f /etc/repmgr/repmgr.conf cluster show
```

Two standby rows, one `* primary`, and the pgcat endpoint answering is a healthy install.
[`Verifying the cluster`](#verifying-the-cluster) has the rest.

---

## Values Reference

Only the keys you are likely to change. `helm show values postgresql/sothanav-ha-pg` prints
everything with its inline comments.

### Identity and placement

| Key | Default | Meaning |
| --- | ------- | ------- |
| `fullnameOverride` | `pg-ha` | Node and volume names; repmgr stores the hostnames, so treat it as permanent |
| `pgcat.fullnameOverride` | `pgcat` | Client host `pgcat.<namespace>.svc` |
| `namespaceOverride` | `""` | Namespace baked into pod hostnames |
| `clusterDomain` | `cluster.local` | DNS suffix in those hostnames |
| `replicas` | `3` | repmgr nodes; below 3 needs `repmgr.failover: manual` |
| `bootstrap.primaryOrdinal` | `0` | Which ordinal runs `initdb` on a cold volume. Keeping it 0 keeps `podManagementPolicy: OrderedReady`; any other value switches the StatefulSet to `Parallel`, because otherwise pod 0 would wait for a primary Kubernetes would never create |
| `terminationGracePeriodSeconds` | `60` | Also bounds `pg_ctl -m fast stop` (the entrypoint uses grace − 10 s) |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | Placement; `affinity` replaces `podAntiAffinity` |
| `podAntiAffinity.enabled` / `.required` | `true` / `false` | Prefer (or require) one node per Kubernetes node |

### Images

| Key | Default | Meaning |
| --- | ------- | ------- |
| `image.registry` | `""` | Prefix; empty when `repository` includes the host |
| `image.repository` | `sothanav/pg-ha` | Published build of `image/Dockerfile`; point it at your own registry to audit or mirror it |
| `image.tag` | `18-repmgr` | Must agree with `repmgr.pgBindir` |
| `image.digest` | `""` | `sha256:…`; replaces the tag in the rendered reference when you want a reproducible install |
| `imagePullSecrets` | `[]` | For a private registry |
| `pgcat.image.repository` | `ghcr.io/postgresml/pgcat` | Upstream, unmodified |
| `pgcat.image.digest` | `""` | pgcat publishes no semver tags; pin the digest for reproducibility |

### Credentials

| Key | Default | Meaning |
| --- | ------- | ------- |
| `auth.existingSecret` | `pg-ha-secret` | Pre-created Secret; the render fails if empty |
| `auth.postgresPasswordKey` | `postgres-password` | Superuser + pgcat pool credential |
| `auth.repmgrPasswordKey` | `repmgr-password` | Replication/monitoring role |
| `auth.pgcatAdminPasswordKey` | `pgcat-admin-password` | pgcat local admin |
| `auth.database` | `postgres` | Bootstrapped database, and the one pgcat pools |
| `auth.repmgrDatabase` | `repmgr` | repmgr's own metadata |

### repmgr and PostgreSQL

| Key | Default | Meaning |
| --- | ------- | ------- |
| `repmgr.failover` | `automatic` | `automatic` or `manual`; the split-brain guard applies either way |
| `repmgr.reconnectAttempts` × `.reconnectInterval` | `4` × `3` | Detection window before a standby calls the primary dead |
| `repmgr.useReplicationSlots` | `true` | Keep WAL a lagging standby still needs (costs disk) |
| `repmgr.primaryWaitSeconds` | `60` | How long a standby waits for a visible primary before starting repmgrd |
| `repmgr.pgcatSyncSeconds` | `5` | Drift-repair interval for the pgcat config on the primary |
| `repmgr.settings` | `{}` | Extra `repmgr.conf` lines; restarts the pods (checksum annotation) |
| `postgresqlConfig` | see file | Appended to `postgresql.conf` **on first init only** |

### pgcat

| Key | Default | Meaning |
| --- | ------- | ------- |
| `pgcat.replicas` | `1` | Stateless poolers; each holds its own pools (`poolSize` each) |
| `pgcat.poolSize` | `30` | Checked against `postgresqlConfig.max_connections` at render time |
| `pgcat.watchIntervalSeconds` | `3` | Sidecar poll interval; pgcat's own `autoreload` is 3 s |
| `pgcat.adminUser` | `pgcat_admin` | pgcat-local admin account, not a PostgreSQL role; rendered through a token, so renaming it is honoured (and it must not collide with `auth.username`) |
| `pgcat.adminDatabase` | `pgcat` | Must NOT be `auth.database` (pgcat refuses admin on a pooled database) |
| `pgcat.service.type` / `.port` / `.nodePort` | `ClusterIP` / `6432` / `null` | Client endpoint |
| `pgcat.service.metricsPort` | `9930` | Service-side port for the exporter |
| `pgcat.configTemplate` | `""` | Full replacement for `files/pgcat.toml.tpl` (`--set-file` works). Must keep the `__SERVERS__`, `__POSTGRES_PASSWORD__` and `__ADMIN_USER__` tokens — the render refuses a template without them |

### Storage, probes, resources

| Key | Default | Meaning |
| --- | ------- | ------- |
| `persistence.storageClass` | `<STORAGE_CLASS>` | RWO class; `""` uses the cluster default |
| `persistence.size` | `20Gi` | Per node |
| `persistence.reclaimPolicy` | `Retain` | `Retain` survives `helm uninstall` |
| `persistence.existingClaim` | `""` | Only usable with `replicas: 1` (the render enforces it) |
| `probes.startup.failureThreshold` | `360` | 5 s × 360 = 30 min for `initdb` or a large clone |
| `probes.liveness.failureThreshold` | `10` | 30 s × 10 = 5 min before a restart |
| `resources` / `pgcat.resources` | see file | Requests and limits |

`probes.startup` does double duty: the chart also injects it as `PGCTL_START_TIMEOUT`, because
`pg_ctl -w` gives up after 60 s by default and a non-zero `pg_ctl start` ends the container —
tearing down a postmaster that was still replaying WAL normally and turning a slow recovery
into a crash loop that never finishes. `pg_ctl -m fast stop` gets
`terminationGracePeriodSeconds − 10` for the same reason.

### Optional objects

| Key | Default | Meaning |
| --- | ------- | ------- |
| `metrics.enabled` | `false` | Master switch for the two objects below; needs the monitoring CRDs |
| `metrics.serviceMonitor.enabled` | `true` | Scrape pgcat's exporter |
| `metrics.prometheusRule.enabled` | `true` | Node-count, pooler-up, PVC-Pending alerts |
| `serviceAccount.create` / `pgcat.serviceAccount.create` / `rbac.create` | `true` / `true` / `true` | The two identities (publisher, reader) and their two Roles; turn any of them off to supply your own |

---

## Connecting

Applications use pgcat. Never point an application at a pod DNS name: it will follow
failovers by breaking, not by reconnecting.

```bash
kubectl -n database run psql --rm -it --restart=Never --image=postgres:18-bookworm -- \
  psql --host pgcat.database.svc --port 6432 --username postgres --dbname postgres
```

Reads spread over the standbys, writes and everything pgcat cannot classify go to the
primary (`default_role = "primary"`, `primary_reads_enabled = false`). Confirm what a
session is attached to:

```sql
SELECT inet_server_hostname(), pg_is_in_recovery();
```

pgcat's own admin console — the database must be one with **no** pool configured, which is
why `pgcat.adminDatabase` defaults to `pgcat`:

```bash
kubectl -n database exec deploy/pgcat -c pgcat -- \
  psql --host 127.0.0.1 --port 6432 --username pgcat_admin --dbname pgcat \
  -c 'SHOW CLIENTS' -c 'SHOW POOLS'
```

Useful admin statements: `SHOW DATABASES`, `SHOW SERVERS`, `SHOW STATS`, `RELOAD`.

---

## How the write endpoint follows the primary

pgcat never calls `pg_is_in_recovery()`; every role comes from its config file. If nobody
rewrites it, writes keep going to the node that used to be primary. The chain in this
chart:

| Step | Where | Latency |
| ---- | ----- | ------- |
| 1. repmgrd decides the upstream is gone and runs `promote_command` | the winning standby | `reconnectAttempts × reconnectInterval` |
| 2. `pgcat-role-sync.sh --force` finds the node where `pg_is_in_recovery()` is `f` | same pod, called by repmgr | up to 20 s of retries while `pg_promote()` finishes |
| 3. It renders `files/pgcat.toml.tpl` and `PATCH`es `pgcat-config` | through the API, RBAC-scoped | one round trip |
| 4. The sidecar GETs the new value, substitutes the passwords, writes `/config/pgcat.toml` | pgcat pod, emptyDir | ≤ `pgcat.watchIntervalSeconds` |
| 5. It sends `RELOAD` to pgcat on 127.0.0.1 | same pod network namespace | instant; pgcat's own `autoreload` (3 s) is the fallback |

Three details are load-bearing:

- **Only the primary node publishes.** The periodic loop checks its own recovery state and
  exits quietly otherwise, so all three nodes can run the same loop without fighting.
- **A failed publish never fails the promotion.** `promote_command` ends in
  `&& { pgcat-role-sync.sh --force || true; }`: if the ConfigMap patch is refused, repmgr
  must still report a clean promotion — otherwise it treats a successful `pg_promote()` as a
  failed failover. The script logs the API's own reason (with a pointer to the RBAC section
  on 403) and the 5-second sync loop retries until it lands.
- **The published value starts empty** and stays empty until a node publishes. The sidecar
  ignores an empty value instead of publishing it — a blank config would make pgcat drop
  every pool. pgcat's container waits for a non-empty file on purpose.
- **`lookup` keeps the live value across `helm upgrade`**, so an upgrade does not reset the
  server list to `bootstrap.primaryOrdinal` and briefly point writes at a demoted node.

---

## Failover drill

Automatic failover that has never been exercised is not automatic failover. Do this on a
test release before trusting a production one.

```bash
# 1. note the current primary and keep writing through pgcat in another terminal
kubectl -n database exec pg-ha-0 -- as-postgres \
  repmgr -f /etc/repmgr/repmgr.conf cluster show

# 2. remove the primary the way a node failure removes it: no chance to shut down
kubectl -n database delete pod pg-ha-0 --force --grace-period=0

# 3. watch: a standby promotes, the ConfigMap follows, pgcat reloads
watch -n2 'kubectl -n database get cm pgcat-config \
  -o jsonpath="{.metadata.annotations}"'

# 4. the killed pod returns and rejoins as a standby (pg_rewind), it does NOT reclaim the role
kubectl -n database logs pg-ha-0 | grep -E 'node rejoin|rewind|standby'
```

> **Warning**: on a cluster where the pod comes back quickly, step 2 tests crash recovery and
> **not** failover: the StatefulSet recreates the pod immediately, and a cached image plus an
> already-attached volume is faster than repmgrd's election (measured on single-node k3s,
> 2026-11-24: primary gone at t+0 s, the same node serving writes again at t+16 s, still the
> primary, nothing republished — correct behaviour, wrong test). Take the node out of service so
> the pod *cannot* return, and the election happens:
>
> ```bash
> NODE=$(kubectl -n database get pod pg-ha-0 -o jsonpath='{.spec.nodeName}')
> kubectl cordon "$NODE"                        # the recreated pod stays Pending
> kubectl -n database delete pod pg-ha-0 --grace-period=0
> # ... promote, republish, writes recover (measured: t+16 s), reads keep splitting ...
> kubectl uncordon "$NODE"                      # the old primary rejoins as a standby
> ```
>
> Measured that way on the real cluster: promoted at t+16 s, the ConfigMap annotation showing the
> new node's FQDN in the same poll, writes rejected with `AllServersDown` for exactly those 16 s
> and landing on the new primary after, the former primary Ready again as a standby at t+42 s, and
> `repmgr cluster show` ending with one primary and two `streaming` standbys on a shared timeline.
>
> Avoid `--force` unless you have to: it is how you clear a pod whose container the runtime could
> not reap (kubelet then reports the container running forever, which blocks the StatefulSet's
> next pod *and* the PVC, whose `Terminating` state in turn blocks `FailedCreate`). If you see
> `Create Pod pg-ha-0 ... failed error: pvc pgdata-pg-ha-0 is being terminated`, that is the
> situation, and `kubectl delete pod --grace-period=0 --force` is the way out — check the pod's
> cgroup on the node first, because the container may still be running.

What to expect, measured against this chart's own scripts on a 3-node cluster (hard kill
of the primary, 1 s write probes through pgcat):
| Observation | Measured |
| ----------- | -------- |
| Promotion starts | after `reconnectAttempts × reconnectInterval` (default 4 × 3 = 12 s of failed pings) |
| A survivor answers `pg_is_in_recovery() = f` | t+10 s … t+14 s |
| ConfigMap annotation shows the new primary | t+11 s … t+14 s (one PATCH, then a ≤3 s sidecar poll) |
| Writes through pgcat succeed again | **t+14 s … t+15 s** |
| Killed node back as a healthy standby | on pod restart, via `repmgr node rejoin --force-rewind` (seconds, in both runs) |

So budget roughly **15 seconds of failed writes** per unplanned primary loss with the
default values, and expect `FATAL: could not get connection from the pool` from clients in
that window — pgcat has no server list it can use yet, which is the failure mode you want
(it refuses) rather than the one it would have without role sync (writing to a demoted
node). Lower `repmgr.reconnectInterval` or `reconnectAttempts` to shorten the window at the
cost of promoting over a node that only stalled on fsync.

`repmgr cluster show` afterwards is worth reading once: the former primary comes back as
`standby ... upstream pg-ha-<winner>`, on timeline 2 while a node that missed the promotion
sits on timeline 1 until it resyncs. That is normal, not a split brain.

The killed node comes back as a **standby** even though it was the original primary —
`bootstrap.primaryOrdinal` records intent for a cold volume, it does not win elections. To
move the role back deliberately:

```bash
kubectl -n database exec pg-ha-1 -- as-postgres \
  repmgr -f /etc/repmgr/repmgr.conf standby switchover
```

---

## Verifying the cluster

Who is who, from PostgreSQL's point of view:

```bash
kubectl -n database exec pg-ha-0 -- as-postgres \
  repmgr -f /etc/repmgr/repmgr.conf cluster show
kubectl -n database exec pg-ha-0 -- as-postgres \
  repmgr -f /etc/repmgr/repmgr.conf node check
```

Streaming, straight from the primary:

```bash
kubectl -n database exec pg-ha-0 -- as-postgres psql -U postgres -d postgres -x -c \
  "SELECT application_name, state, sync_state,
          pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag_bytes
   FROM pg_stat_replication"
```

What pgcat is configured to do right now:

```bash
kubectl -n database get cm pgcat-config -o jsonpath='{.metadata.annotations}{"\n"}'
kubectl -n database get cm pgcat-config -o jsonpath='{.data.pgcat\.toml}' | grep -A4 'servers'
```

Repmgrd liveness on a specific node (a supervisor restarts it, so a crash is recoverable
but should be visible in the log):

```bash
kubectl -n database logs pg-ha-1 | grep -E 'repmgrd exited|starting up repmgrd'
```

---

## RBAC

The pods call the Kubernetes API, so the chart ships two ServiceAccounts and two Roles —
deliberately not one identity for everything:

| Identity | Bound to | Verbs on the published ConfigMap |
| -------- | -------- | -------------------------------- |
| `pg-ha` (database pods) | `…-publisher` | `get`, `patch` — role-sync publishes a new server list |
| `pgcat` (pooler pod) | `…-reader` | `get` only |

```yaml
# both roles, differing only in the verb list
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["pgcat-config"]
    verbs: ["get", "patch"]   # or ["get"] for the pooler
```

`resourceNames` pins each rule to the one ConfigMap pgcat reads, so neither pod can read the
namespace's other ConfigMaps. No `list`, no `watch`, no `create`: the scripts poll, which is
what keeps the grant to a single named object instead of a collection.

Why the pooler does not also get `patch`: the sidecar substitutes the real database password
into *whatever* server list the ConfigMap contains. If the pooler could write that ConfigMap,
compromising a process that is a NodePort away from the internet would be enough to point the
pool at an attacker's host and have the sidecar hand it a valid credential with a live
password. Read is the most the pooler has ever needed, so read is all it gets.

Set `serviceAccount.create=false` and/or `pgcat.serviceAccount.create=false` with a `name` to
bring your own identities; `rbac.create=false` skips both Roles. You then have to provide the
verbs above yourself on `pgcat.fullnameOverride`-`-config` (default `pgcat-config`). Symptoms
of a wrong grant: `HTTP 403` in the sidecar log (`…-reader` missing) or in role-sync
(`…-publisher` missing, and pgcat frozen on an old server list).

---

## Security

| Choice | Why |
| ------ | --- |
| Database container starts as root, drops to uid 999 with `as-postgres` (`setpriv`) | The `postgres` image contract: it chowns the volume, then steps down. `podSecurityContext.runAsNonRoot: true` or `allowPrivilegeEscalation: false` makes the pod unstartable, and the render refuses both. `as-postgres` rather than the base image's gosu because it also works on a node whose AppArmor profile withholds signals (next row); `/usr/local/bin/gosu` is a symlink to it, so nothing else has to change |
| AppArmor is not disabled, but a node profile that refuses `signal send` breaks PostgreSQL completely | See [AppArmor](#apparmor-a-node-profile-that-refuses-signal-kills-postgres-silently) below |
| `capabilities.drop: [ALL]` with `CHOWN, SETUID, SETGID, FOWNER, DAC_OVERRIDE, KILL` added | Exactly what the root phase needs; no `SYS_ADMIN`, no privileged mode |
| `fsGroup: 999` | Freshly provisioned volumes become group-writable before the chown |
| `enableServiceLinks: false` | Other workloads' `_SERVICE_PORT` variables stay out of the entrypoint's environment; the scripts default `KUBERNETES_SERVICE_HOST` to `kubernetes.default.svc:443` |
| `automountServiceAccountToken: true` | The only reason the pods need an identity at all; both scripts re-read the token every round, so bounded-token rotation is invisible |
| Sidecar runs as uid 999, non-root, `readOnlyRootFilesystem: true`, one emptyDir mounted | Its writable surface is that single directory, and the script is written to match: every scratch file is created **next to the output file**, never in `/tmp`. With a read-only root and no `/tmp`, a bare `mktemp` fails, the sidecar reports `HTTP 000` forever, and pgcat never receives a config — a failure that cannot be seen outside a cluster, so `readOnlyRootFilesystem` is asserted in the render checks and exercised in a `docker run --read-only` test |
| No Secret volume mounts | `secretKeyRef` env only; nothing credential-shaped appears in a rendered manifest |
| The replication password is never in `repmgr.conf` | repmgr stores the `conninfo` it is given **verbatim** in its `repmgr.nodes` table and prints it in `cluster show`, so a password there would be replicated into the metadatabase on all three volumes and appear in runbooks and DEBUG logs. The chart puts `passfile=/var/lib/postgresql/.pgpass` in the conninfo instead; that file is rebuilt from the Secret at every container start and lives in the image layer, not on the PVC. (repmgr has no `pass_file` configuration key — 5.5 ignores unknown keys with a warning, verified against the binary) |
| `PGPASSFILE` is a container env var, not just an entrypoint export | `kubectl exec` builds a fresh environment from the pod spec, so every `repmgr cluster show` / `node check` in the runbooks needs it to find the password file |
| `initdb --pwfile` is unlinked as soon as `initdb` returns | It is the only on-disk copy of the superuser password in the container; `.pgpass` holds the replication role, not this one |

`pg_hba.conf` on a bootstrapped cluster allows `scram-sha-256` from `0.0.0.0/0` (cluster
network), same as the compose stack. Restrict who can reach the pods with a NetworkPolicy
of your own — this chart does not render one, because a wrong policy breaks replication
before anyone notices.

### AppArmor: a node profile that refuses `signal` kills Postgres silently

PostgreSQL wakes nearly all of its own processes with a latch signal, and PostgreSQL 18 sends
those on **`SIGURG`**: an `io worker` (the default `io_method = worker`) reads a page and then
signals the backend that asked for it, the checkpointer signals the backends that are waiting for
a flush, the postmaster signals every child. If an LSM refuses that `kill()`, the postmaster
starts, `initdb` succeeds, the log reaches `database system is ready to accept connections` —
and **every connection then hangs forever**, so the readiness probe never passes, `pg_isready`
never answers, the pod sits at `0/1`, and the log fills with `sorry, too many clients already`.
Nothing PostgreSQL prints mentions the cause. Measured on k3s v1.36.5 / containerd 2.3.4 /
Ubuntu 26.04.1 (kernel `7.0.0-43-generic`), 2026-11-24:

```console
# every backend parked, forever, in the latch wait:
$ kubectl exec <pod> -- sh -c 'cat /proc/<backend>/wchan'    ep_poll

# the io worker finished the read and could not report it:
$ strace -f -p <io worker>
  pread64(7, "\0\0\0\0H9P\1..."..., 8192, 0) = 8192
  kill(106, SIGURG)          = -1 EACCES (Permission denied)

# the reason:
$ dmesg | grep DENIED | tail -1
  apparmor="DENIED" operation="signal" class="signal" profile="cri-containerd.apparmor.d"
    comm="postgres" requested_mask="send"
```

`cri-containerd.apparmor.d` is a profile **containerd generates itself** (it is not in
`/etc/apparmor.d`), and containerd 2.x applies it to every pod by default:
`default_app_armor_profile` defaults to `runtime/default`, where containerd 1.x left containers
unconfined. That ruleset predates AppArmor 4 signal mediation and grants no `signal` permission at
all, so it also refuses signals between two processes of the *same* container and *same* uid.
Any Postgres workload on such a node is broken, not only this chart.

Two fixes. Prefer the first if anything else runs on the cluster:

| Fix | How |
| --- | --- |
| Node (every workload benefits) | Tell containerd to stop applying the profile: in k3s, write `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` with `default_app_armor_profile = "unconfined"` under `[plugins."io.containerd.cri.v1.runtime"]` and restart k3s. Or load a profile of your own that allows `signal (send receive) set=` between the container's own processes |
| This chart only | `podSecurityContext.appArmorProfile.type: Unconfined` — and the same under `pgcat.podSecurityContext` if you want it there. The render checks the value (an empty or unknown `type` is a pod the API rejects), and Kubernetes only refuses `Unconfined` on clusters that explicitly restrict it |

Find out what a pod actually got — an absent field is the interesting case, because it means
"whatever containerd defaults to":

```bash
kubectl get pod <pod> -o jsonpath='{.spec.securityContext.appArmorProfile}{"\n"}'
kubectl exec <pod> -- cat /proc/1/attr/current     # unconfined, or "cri-containerd.apparmor.d (enforce)"
```

---

## Scaling and replacing nodes

```bash
helm upgrade pg-ha postgresql/sothanav-ha-pg -n database \
  -f postgresql/sothanav-ha-pg/values.local.yaml --set replicas=5
```

Ordinal 4 joins with `standby clone` from the bootstrap primary's host. Then verify with
`repmgr cluster show`.

Two things Kubernetes does not do for you:

- **Scaling down leaves registrations behind.** repmgr keeps a row per node in its own
  database, and the StatefulSet's `whenScaled: Retain` keeps the volume. Before reducing
  `replicas`, remove the node properly:

  ```bash
  kubectl -n database exec pg-ha-4 -- as-postgres \
    repmgr -f /etc/repmgr/repmgr.conf node unregister
  kubectl -n database delete pvc pgdata-pg-ha-4
  ```

- **A node whose volume is gone is a new node.** With an empty volume, `standby clone`
  rebuilds it, but the ordinal's `node_id` (ordinal + 1) must not collide with a stale
  registration — `repmgr node register` fails rather than overwriting. Unregister first.

Even node counts are allowed but warned about in `NOTES.txt`: without a majority, two
halves of a partitioned 4-node cluster can each promote.

### Node drains

This chart ships no PodDisruptionBudget: with `replicas: 3` and automatic failover, the
choice of `minAvailable` is a policy decision about your maintenance windows, not a property
of the database. That leaves drains free to evict two of three pods at once, which is a
promotion with no quorum behind it. If node maintenance is routine, add one yourself:

```bash
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pg-ha
  namespace: database
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: sothanav-ha-pg
      app.kubernetes.io/component: database
EOF
```

`minAvailable: 2` blocks a drain until a replacement is Ready, which is what you want for the
volumes too: an RWO volume cannot move until the pod using it has stopped.

---

## Rotating the passwords

All three live in one Secret, and every consumer reads it at container start.

```bash
kubectl -n database create secret generic pg-ha-secret \
  --from-literal=postgres-password="<NEW>" \
  --from-literal=repmgr-password="<NEW>" \
  --from-literal=pgcat-admin-password="<NEW>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then, in order:

1. **PostgreSQL role passwords** — the Secret alone does not change them. On the primary:

   ```sql
   ALTER USER postgres WITH PASSWORD '<NEW>';
   ALTER USER repmgr  WITH PASSWORD '<NEW>';
   ```

2. **Restart the database pods** so the entrypoint rewrites `.pgpass`:

   ```bash
   kubectl -n database rollout restart statefulset/pg-ha
   ```

3. **Restart pgcat** so the sidecar picks up the new pool credential:

   ```bash
   kubectl -n database rollout restart deployment/pgcat
   ```

`replication` connections authenticate with the `repmgr` role password, so step 1 must
succeed before step 2 — otherwise the standbys cannot stream mid-rollout. Do it one pod at
a time (`rollout restart` already does).

---

## Upgrading the chart

```bash
helm diff upgrade pg-ha postgresql/sothanav-ha-pg -n database \
  -f postgresql/sothanav-ha-pg/values.local.yaml
helm upgrade pg-ha postgresql/sothanav-ha-pg -n database \
  -f postgresql/sothanav-ha-pg/values.local.yaml
```

What moves and what does not:

| Change | Effect |
| ------ | ------ |
| `postgresqlConfig` | Written to the ConfigMap, but PostgreSQL only reads it during `initdb` on an empty volume. Apply with `ALTER SYSTEM` + `SELECT pg_reload_conf()`, or the `checksum/conf` annotation restarts pods that ignore it |
| `repmgr.settings` | Same ConfigMap, read at every pod start; the checksum annotation rolls the pods for you |
| `pgcat.configTemplate` | Flows through the ConfigMap; the sidecar re-renders within one poll. No pod restart, and a broken template leaves the old pools running instead of dropping every client |
| `image.tag` | Rolling update, highest ordinal first, so the initial primary restarts last |
| `replicas`, resources, probes | Normal StatefulSet rollout |
| `fullnameOverride`, `bootstrap.primaryOrdinal`, `pgcat.serverPort`, `auth.database` | **Do not change on a live release**: repmgr's own metadata and pgcat's pool names contain those values. Rebuild instead |

`helm rollback` re-renders everything except the published ConfigMap key, which stays
whatever the cluster last published — usually what you want mid-incident.

A rolling update restarts the nodes one at a time, highest ordinal first, and each one rejoins
as a standby in about 10 s (measured on the real cluster, 2026-11-24: three pods moved to a new
`image.digest`, all Ready at t+42 s, no promotion — every shutdown was graceful, so repmgrd
never saw a failure). Clients do see one thing during it: pgcat **bans** a server whose
connection dies, for `ban_time` in `files/pgcat.toml.tpl` (10 s; the whole template is yours to
change with `pgcat.configTemplate`), and a rollout takes all three down in turn. So writes can
still fail with `FATAL: could not get connection from the pool - AllServersDown` for up to
`ban_time` *after* the last pod reports Ready — pod readiness is not pool readiness here. Wait
those seconds, or have the client retry.

---

## Troubleshooting

Start with the two questions that separate most failures: *who does PostgreSQL think is
primary*, and *what has pgcat been told*.

```bash
# who is primary, from each node's own point of view
for i in 0 1 2; do kubectl -n database exec pg-ha-$i -- as-postgres psql -U postgres \
  -d postgres -tAc 'SELECT pg_is_in_recovery()'; done

# what pgcat was told, and by whom
kubectl -n database get cm pgcat-config -o jsonpath='{.metadata.annotations}{"\n"}'

# is this node allowed to auto-promote? automatic = yes, manual = split-brain guard active
kubectl -n database exec pg-ha-1 -- grep ^failover /etc/repmgr/repmgr.conf
```

| Symptom | Cause and fix |
| ------- | ------------- |
| pg-ha-1/2 crash-loop with "clone target not ready", then settle | Normal on a cold install: OrderedReady is waiting for ordinal 0. Only a problem if ordinal 0 never becomes Ready |
| Pod Ready but `repmgr cluster show` says "registered as an active primary but is unreachable" | The node was hard-killed and another won. The surviving node rejoins on restart; check `logs <pod> \| grep rejoin` |
| Log says `starting repmgrd in monitoring-only mode (failover=manual)` | Split-brain guard: this node has `standby.signal` and never saw a primary within `repmgr.primaryWaitSeconds`. If the primary really is gone, promote deliberately: `repmgr standby promote -f /etc/repmgr/repmgr.conf` |
| `pgcat-role-sync: PATCH failed ... (HTTP 403)` | RBAC: the `…-publisher` Role/RoleBinding is missing, `pgcat.fullnameOverride` changed so `resourceNames` points at the old name, or the database pod is running with the pooler's ServiceAccount (which has `get` only, on purpose) |
| Sidecar logs `refusing to write a config in which __SERVERS__ was never substituted` | The published text did not come from this chart's role-sync — someone edited the ConfigMap by hand, or an older image published it. The previous working config stays live; fix the publisher, do not the file |
| `fe_sendauth: no password supplied` from an exec'd `repmgr` command | `PGPASSFILE` is not in the environment you used. `kubectl exec` starts from the pod spec's env, which the chart sets; a bare `docker exec`/`nsenter`-style shell does not inherit it. Use `kubectl exec … -- as-postgres repmgr …` as the runbooks show |
| Sidecar logs `GET … failed (HTTP 000)` with no curl error, forever, and pgcat never starts | The sidecar has nowhere to write: it needs the emptyDir at `/config` and nothing else, and it deliberately creates its scratch files there. A `readOnlyRootFilesystem: true` with an extra read-only mount at `/config` produces exactly this |
| Sidecar logs `no config published yet` forever | No node has published: check the primary's role-sync log, the Secret keys, and the RBAC above |
| Writes fail with `AllServersDown` while all pods are Ready | pgcat's server list is stale, or every listed server is banned. `SHOW SERVERS` on the admin console; check the sidecar is running (`kubectl logs deploy/pgcat -c config-watcher`) |
| `cannot execute ... in a read-only transaction` | The pooler still points at a demoted node — the publication chain is broken at some step above. Confirm with `kubectl get cm pgcat-config -o jsonpath='{.metadata.annotations}'` |
| `repmgr node rejoin` fails with "cannot run pg_rewind" | The demoted node's `postgresql.conf` lacks `wal_log_hints = on` (it is in `postgresqlConfig` for a reason) or timelines diverged past recovery: rebuild that node's PVC and let `standby clone` refill it |
| PVC stuck `Pending` | StorageClass typo or quota. `kubectl describe pvc pgdata-pg-ha-0` |
| Pod stays `0/1`; the server log ends at `database system is ready to accept connections`; every connection (even `pg_isready`) hangs and the log fills with `sorry, too many clients already`; backends park in `ep_poll` | The node's AppArmor profile refuses PostgreSQL's own latch signals: an io worker's `kill(backend, SIGURG)` returns `EACCES` and `dmesg` shows `apparmor="DENIED" operation="signal"`. Nothing PostgreSQL prints hints at it. Set `podSecurityContext.appArmorProfile.type: Unconfined`, or fix containerd's default profile (README: [AppArmor](#apparmor-a-node-profile-that-refuses-signal-kills-postgres-silently)) |
| A `gosu ...` command hangs at 100% CPU and `kill -9` will not reap it | Same AppArmor denial — gosu cannot signal the child it forked. `as-postgres` works on that node, which is why the image and every command in this README use it |
| `ImagePullBackOff` | `image.repository` points at a path that was never pushed, the tag does not exist there, `imagePullSecrets` is missing for a private registry, or the nodes have no Docker Hub egress (build your own and point `image.repository` at it) |
| Replication lag grows to `max_slot_wal_keep_size` | A standby is too far behind; past that size the slot is invalidated and the node needs a reclone. Raise `repmgr.useReplicationSlots` trade-off or fix the standby |
| `ERROR: could not open ... postmaster.pid` after a forced delete | Handled: the entrypoint removes a stale PID file on reboot. If it persists, the volume is mounted by another pod — check `accessModes` |

---

## Differences from the compose stack

Same cluster logic, deliberately. Everything below is a Kubernetes reality rather than a
design change, and the two directories should be read together.

| Compose | Chart | Why |
| ------- | ----- | --- |
| Shared named volume `pgcat_conf` between all containers | ConfigMap + sidecar + emptyDir | No ReadWriteMany StorageClass involved, and each database pod keeps a private RWO volume |
| `depends_on` for boot order | `podManagementPolicy: OrderedReady` | The StatefulSet needs a Ready ordinal 0 before creating ordinal 1 |
| `NODE_ID`/`NODE_NAME` in `.env` | Derived from the pod (ordinal + 1, pod name) | Stable across restarts, rollouts and node replacements |
| `pg1,pg2,pg3` short hostnames | `<pod>.<headless>.<ns>.svc.<domain>` FQDNs | A bare pod name does not resolve through a headless Service |
| `pgcat.toml.tpl` edited on the host | `files/pgcat.toml.tpl` (or `pgcat.configTemplate`) in a ConfigMap | No image rebuild needed, and `helm diff` shows the change |
| pgcat shared one `pgcat.toml` file | Sidecar polls the API every `watchIntervalSeconds` and writes the emptyDir | Mounting the ConfigMap directly would let kubelet's own sync interval (up to a minute) delay failover propagation |
| Passwords in `.env` | One pre-created Secret, `secretKeyRef` per consumer, and the published ConfigMap holds tokens, not secrets | Nothing credential-shaped in a manifest or in ConfigMap reads |
| `PRIMARY_HOST=pg1` also decided the leader | `bootstrap.primaryOrdinal` only decides who runs `initdb` | repmgrd runs elections; a hard-killed primary rejoins as a standby |
| Split-brain guard keyed on the designated primary's name | Guard keyed on `standby.signal` in the data directory | After any failover, "the designated primary" and "the node that should promote" are unrelated things |
| Replication password in `conninfo`, so `repmgr cluster show` prints it | `passfile=` in `conninfo`, password file rebuilt from the Secret at each start | repmgr stores `conninfo` verbatim in `repmgr.nodes`, so a password there is replicated to every volume and printed in every runbook command |
| pgcat's admin username edited in the shared `pgcat.toml.tpl` | `__ADMIN_USER__` token filled by the same process that authenticates the `RELOAD` | A renamed admin user that pgcat and the sidecar disagree about breaks every reload, silently |

---

## References

- repmgr: <https://repmgr.org/> (5.5 in the image) — `repmgr cluster show`, `node check`,
  `standby switchover`, `node rejoin`
- pgcat: <https://github.com/postgresml/pgcat> — pooling modes, query parser, exporter
- PostgreSQL 18 replication: <https://www.postgresql.org/docs/current/wl-repmgr.html>,
  `pg_rewind` under <https://www.postgresql.org/docs/current/pgrewind.html>
- Official image with the moved `$PGDATA`: <https://hub.docker.com/_/postgres>
- StatefulSet guarantees (ordering, stable network IDs):
  <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>
