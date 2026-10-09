# InfluxDB Cluster — self-contained chart

Helm chart for [InfluxDB Cluster](https://github.com/chengshiwen/influxdb-cluster)
(the open-source re-implementation of InfluxDB Enterprise): N meta nodes holding the
raft metadata plane, M data nodes storing series, forming an actual cluster on
`helm install` — the join that upstream's chart leaves to a human running
`influxd-ctl` is done by a hook Job in this chart. Chart templates live in
[`chart/`](chart/), no upstream-chart dependency, every rendered line editable here.

## Table of Contents

- [Files](#files)
- [What This Chart Adds Over Upstream](#what-this-chart-adds-over-upstream)
- [Prerequisites](#prerequisites)
- [Secrets](#secrets)
- [Installation](#installation)
- [Values Reference](#values-reference)
- [How the Cluster Forms](#how-the-cluster-forms)
- [Verify](#verify)
- [Connecting](#connecting)
- [Authentication](#authentication)
- [Databases and Replication Factor](#databases-and-replication-factor)
- [Scaling](#scaling)
- [Restart Semantics](#restart-semantics)
- [Probes](#probes)
- [Changing Ports or Names](#changing-ports-or-names)
- [Backup and Restore](#backup-and-restore)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Files

| File | Purpose |
| ---- | ------- |
| `chart/Chart.yaml` | `appVersion` tracks the image tag (`1.8.11-c1.2.0`) |
| `chart/values.yaml` | Default values, with `<STORAGE_CLASS>` to fill in |
| `chart/templates/meta-statefulset.yaml` | Meta nodes: `-single-server` at 1 replica, config checksum annotation |
| `chart/templates/data-statefulset.yaml` | Data nodes: inputs ports, WAL-friendly `terminationGracePeriodSeconds` |
| `chart/templates/meta-configmap.yaml` | `influxdb-meta.conf` — no secrets, no per-pod values |
| `chart/templates/data-configmap.yaml` | `influxdb.conf` — `[data]`, `[http]`, inputs, `data.rawExtra` escape hatch |
| `chart/templates/service-headless.yaml` | Governing Services; the per-pod DNS the nodes advertise |
| `chart/templates/data-service.yaml` | Client entry point: `influxdb-cluster-data.<ns>.svc:<port>` |
| `chart/templates/meta-service.yaml` | Stable ClusterIP for `influxd-ctl -bind` |
| `chart/templates/join-job.yaml` | Hook Job + ConfigMap with the join script and address lists |
| `chart/files/join.sh` | The join/seed script (plain POSIX sh, `sh -n` checkable) |
| `chart/templates/{pdb,serviceaccount,data-ingress}.yaml` | Budgets, optional ServiceAccount, optional Ingress |
| `chart/templates/tests/test-connection.yaml` | `helm test` pod: ping → SHOW SERVERS → write → read → drop |
| `chart/templates/_helpers.tpl` | Naming, addresses, TOML rendering, auth env, `validate` |
| `chart/templates/NOTES.txt` | Post-install output: join-log command, write/query examples |

---

## What This Chart Adds Over Upstream

The upstream chart
([influxtsdb/helm-charts `charts/influxdb-cluster`](https://github.com/influxtsdb/helm-charts))
installs the pods and prints instructions: *run `influxd-ctl add-meta` for each meta
pod, then `add-data` for each data pod*. Until someone does that, the release is pods
that never talk — meta nodes log `Waiting for leader...` forever, data nodes retry
`meta service unavailable`.

| Concern | Upstream chart | This chart |
| ------- | -------------- | ---------- |
| Join | Manual `influxd-ctl` after every install | post-install/post-upgrade Job runs the same commands |
| Identity | Manual hostnames | per-pod FQDN injected as `INFLUXDB_HOSTNAME`; StatefulSet ordinals make the advertised address reproducible across restarts |
| Seed | Manual | `cluster.databases` + `cluster.adminUser` via the same Job |
| Scale-out | Manual again | `--set data.replicas=4`; the hook re-runs and registers only the missing addresses |
| Misconfiguration | Silent | render-time validation (even meta count, replication > data nodes, placeholder StorageClass, chart-owned config keys, ...) |
| Data-node init scripts | Image default | deliberately absent — see [Troubleshooting](#troubleshooting) for why the OSS init path corrupts a cluster node |

---

## Prerequisites

- Kubernetes 1.21+ (StatefulSet `persistentVolumeClaimRetentionPolicy`), Helm 3.8+
  (chart uses no v4-only features; verified with Helm 4)
- A StorageClass for `ReadWriteOnce` volumes: `kubectl get storageclass`. Put the real
  value in `chart/values.local.yaml` (gitignored pattern `*.local.yaml`), never commit it
- **3 odd meta nodes minimum for HA** — with 2 meta nodes there is no quorum after any
  loss and the render rejects even counts outright
- The Secrets from the next section, created in the release namespace first

---

## Secrets

The chart never renders secret values into objects — values reference Secret names only.
Create both before installing (the second one can wait until you turn authentication on):

```bash
kubectl -n <namespace> create secret generic influxdb-cluster-admin-secret \
  --from-literal=username=admin \
  --from-literal=password="<HTTP_ADMIN_PASSWORD>"

kubectl -n <namespace> create secret generic influxdb-cluster-meta-secret \
  --from-literal=shared-secret="<SHARED_SECRET>" \
  --from-literal=meta-internal-shared-secret="<INTERNAL_SHARED_SECRET>"
```

- The admin Secret is consumed by the join Job (creates the user through the cluster
  API) and by `helm test` once HTTP auth is on.
- `meta-internal-shared-secret` signs node↔node and `influxd-ctl` JWTs;
  `shared-secret` signs user-facing bearer tokens. **Two different values, both ≥ 16
  characters** — reusing one defeats the separation.
- Keys are configurable via `cluster.adminUser.{userKey,passwordKey}` and
  `cluster.auth.{sharedSecretKey,internalSharedSecretKey}`.

---

## Installation

Commands run from this directory. Render first — the validators in
`_helpers.tpl` reject the placeholder StorageClass and everything else that would
install a broken cluster:

```bash
cat > chart/values.local.yaml <<'EOF'
meta:
  persistence:
    storageClass: <STORAGE_CLASS>
data:
  persistence:
    storageClass: <STORAGE_CLASS>
cluster:
  databases:
    mydb: 2                  # must be <= data.replicas
EOF

helm lint chart -f chart/values.local.yaml
helm template influx chart -f chart/values.local.yaml | less
```

Install:

```bash
helm install influx chart -n <namespace> -f chart/values.local.yaml
```

Helm **blocks** until the post-install hook Job finishes — that is the cluster forming
(often < 60s the first time on a fast provisioner, longer while images pull). While it
runs, in another terminal:

```bash
kubectl -n <namespace> logs job/influxdb-cluster-join -f
```

Expected tail of a healthy run:

```
[join ...] all meta nodes are members
[join ...] meta cluster: 3/3
[join ...] all data nodes are members
[join ...] created user admin (admin=true)
[join ...] created database mydb (replication 2)
[join ...] done
```

With the default `hookDeletePolicy: [before-hook-creation, hook-succeeded]` the Job and
its pod are deleted right after a successful run, so `kubectl logs job/...` afterwards
finds nothing. That is by design (clean namespace, re-runnable hook); remove
`hook-succeeded` from `cluster.joiner.hookDeletePolicy` to keep the log as the install
record.

---

## Values Reference

Only the knobs with non-obvious cluster consequences are listed; `values.yaml` comments
cover the rest.

| Key | Default | Notes |
| --- | ------- | ----- |
| `fullnameOverride` | `influxdb-cluster` | Pinned so clients use `influxdb-cluster-data.<ns>.svc` regardless of release name |
| `namespaceOverride` / `clusterDomain` | `""` / `cluster.local` | Baked into advertised pod hostnames — changing either after install means re-forming (see [Changing Ports or Names](#changing-ports-or-names)) |
| `image.tag` | `1.8.11-c1.2.0` | Renders to `<tag>-meta` and `<tag>-data`; `image.digest: {meta:, data:}` pins both |
| `meta.replicas` | `3` | 1 (starts with `-single-server`) or odd ≥ 3 |
| `data.replicas` | `2` | Upper bound for every replication factor |
| `*.persistence.storageClass` | `<STORAGE_CLASS>` | Placeholder rejected at render; `""` = cluster default |
| `data.service.port` | `8086` | Client port on the Service (container port stays `ports.dataHTTP`) |
| `cluster.joiner.enabled` | `true` | Off = install never joins, NOTES prints the manual commands |
| `cluster.joiner.hooks` | `[post-install, post-upgrade]` | post-upgrade is what makes scale-out self-service |
| `cluster.joiner.hookDeletePolicy` | `[before-hook-creation, hook-succeeded]` | `before-hook-creation` is required and enforced at render |
| `cluster.joiner.joinOnly` | `false` | Join only, no user/database seeding |
| `cluster.databases` | `{mydb: 2}` | name → replication; created via `CREATE DATABASE "<n>" WITH REPLICATION f` |
| `cluster.waitFor.*` | `300/180/300` | Budgets for pod ports, raft leader, data join |
| `cluster.allowEphemeral` | `false` | Must be true for any `persistence.enabled: false` to render |
| `cluster.adminUser.*` | enabled, `influxdb-cluster-admin-secret` | The Job creates this user after the leader exists |
| `cluster.auth.http` / `.meta` | `false` / `false` | Phase 2 / phase 3 — see [Authentication](#authentication) |
| `cluster.auth.acknowledged` | `""` | Non-empty string asserting an admin user already exists; required to turn either flag on |
| `*.probeMode.*` | `tcp` | Why http is the wrong default: [Probes](#probes) |
| `data.rawExtra` | `""` | Verbatim TOML for `[[...]]` sections flat YAML cannot express |
| `initContainers.chownData.enabled` | `false` | Only for non-root pods on provisioners that ignore fsGroup |

---

## How the Cluster Forms

Three moving parts. All were verified on a live single-node k3s cluster (3 meta + 2→3 data).

### 1. Identity: the advertised address IS the pod's DNS name

Each node must tell the cluster one stable address that every other node can dial.
Both StatefulSets patch the pod's own identity into `INFLUXDB_HOSTNAME` before exec'ing
the binary (the images' env-var override path — TOML does not expand `${VAR}`):

```
influxdb-cluster-meta-0.influxdb-cluster-meta-headless.<ns>.svc.cluster.local
influxdb-cluster-data-0.influxdb-cluster-data-headless.<ns>.svc.cluster.local
```

Those are exactly the addresses `influxd-ctl show` lists after a successful join. The
StatefulSet + headless Service pair makes them recreate identically on every restart,
which is what lets the raft peers and the data nodes' cached `client.json` survive a
pod delete (see [Restart Semantics](#restart-semantics)).

### 2. Registration: the hook Job runs `influxd-ctl`

`chart/files/join.sh`, mounted with three rendered address/user lists:

1. wait for every meta pod's API port (any HTTP reply counts — with auth on, 401 means
   the listener is up)
2. `add-meta` for every listed meta address not already in `influxd-ctl show`. The
   first call bootstraps the raft group on its `-bind` node — that is why `-bind` is
   meta-0 and why ordinal 0 already holds the raft store in its PVC
3. wait until the full meta peer set answers
4. `add-data` for every data pod (each data node opens its TCP port even while it is
   still logging `meta service unavailable`, which is the state they sit in until here)
5. seed: create `cluster.adminUser` (unless `joinOnly`), then one `CREATE DATABASE`
   per `cluster.databases` entry

Re-running is cheap and converges: registration steps skip what `show` already lists,
and seeding tolerates `already exists` replies. **One real Hazard:** `add-meta`/`add-data`
key membership on the exact address, so renaming the release/namespace/`fullnameOverride`
leaves the OLD addresses as phantom members — remove them with `remove-meta`/`remove-data`
(see [Changing Ports or Names](#changing-ports-or-names)).

### 3. Seeding quirks that bit during development

- **No `IF NOT EXISTS` in InfluxQL.** This fork answers
  `CREATE DATABASE IF NOT EXISTS` with `error parsing query: found NOT` (matches
  InfluxDB 1.x). The script uses plain `CREATE` and treats the `already exists`
  reply as success, which is also what makes re-runs converge.
- **The data image's OSS init script is a footgun, not a feature.** The stock
  `/init-influxdb.sh` triggers on `INFLUXDB_DB`, `INFLUXDB_ADMIN_*`, or any file in
  `/docker-entrypoint-initdb.d`, and bootstraps by starting a throwaway **standalone**
  influxd over the cluster's data directory. The chart therefore never mounts or sets
  any of those, and `validate` rejects those env names if you add them by hand.
- **`helm upgrade` always runs the post-upgrade hook** — even when nothing changed —
  and blocks until the hook completes, so re-seeding is one no-op upgrade away.

---

## Verify

```bash
# ledger view (add -auth-type jwt -secret <INTERNAL_SHARED_SECRET> -user "" once meta auth is on)
kubectl -n <namespace> exec influxdb-cluster-meta-0 -- influxd-ctl -bind localhost:8091 show

# client-visible view
kubectl -n <namespace> exec influxdb-cluster-data-0 -- \
  curl -sS --data-urlencode 'q=SHOW SERVERS' 'http://localhost:8086/query'
```

Expected (each node listed exactly once, no old-address phantoms): 3 `Meta Nodes` →
`influxdb-cluster-meta-{0,1,2}....:8091`, `Data Nodes` →
`influxdb-cluster-data-{0,1}....:8088`. `SHOW SERVERS` is the InfluxQL for this —
`SHOW DATA NODES` does not exist (it is an `influxd-ctl` concept and the parser says so).

Then the end-to-end test (pings through the Service, `SHOW SERVERS`, one write, one
read back, drops its own `helm_smoke_test` database):

```bash
helm test influx -n <namespace> --logs
```

Expected: `Phase: Succeeded`, `PASS` at the end of the logs.

---

## Connecting

Applications talk to ONE URL; any data node accepts writes for the whole cluster
(forwarding or hinted-handoff-queuing what it does not own):

```
http://influxdb-cluster-data.<namespace>.svc.cluster.local:8086
```

```bash
# write
curl -XPOST "http://influxdb-cluster-data.<namespace>.svc.cluster.local:8086/write?db=mydb" \
  --data-binary 'cpu,host=s1 load=42i '$(date +%s%N)

# query — the database must come from the `db` parameter or a fully-qualified
# measurement ("db"."rp".measurement); a bare SELECT with no db is answered
# {"error":"database name required"}
curl -G "http://influxdb-cluster-data.<namespace>.svc.cluster.local:8086/query" \
  --data-urlencode 'db=mydb' --data-urlencode 'q=SELECT * FROM cpu LIMIT 5'
```

From outside the cluster: the Service is ClusterIP by design, so use your own proxy or
set `data.service.type: NodePort`. `data.ingress.enabled: true` publishes HTTP 8086 —
with `cluster.auth.http` still false, that is an **unauthenticated read/write database
on that hostname.**

Inputs (`graphite`/`collectd`/`opentsdb`/`udp`) become enabled listener sections AND
Service ports together when their `enabled: true` flag is set.

---

## Authentication

Turn it on in exactly this order — it is enforceable, not stylistic: the meta HTTP API
answers `must create admin user first` to *every* request (even `/ping`) the moment
`[meta] auth-enabled = true` without an admin user in raft, and that user can only be
created through the same API. The chart rejects `cluster.auth.*: true` at render time
until both `cluster.adminUser.enabled` and a non-empty `cluster.auth.acknowledged` are
set.

```bash
# Phase 1 — install (both flags false). The Job creates the admin user
helm install influx chart -n <namespace> -f chart/values.local.yaml

# confirm the subject of phase 2 exists
kubectl -n <namespace> exec influxdb-cluster-data-0 -- \
  curl -sS --data-urlencode 'q=SHOW USERS' 'http://localhost:8086/query'
# expect: values":[["<admin-user>",true]]

# Phase 2 — data HTTP API requires credentials ([http] auth-enabled)
helm upgrade influx chart -n <namespace> -f chart/values.local.yaml \
  --set cluster.auth.http=true --set cluster.auth.acknowledged=2026-10-09

# Phase 3 — meta API requires credentials ([meta] auth-enabled + JWT for influxd-ctl)
helm upgrade influx chart -n <namespace> -f chart/values.local.yaml \
  --set cluster.auth.http=true --set cluster.auth.meta=true \
  --set cluster.auth.acknowledged=2026-10-09
```

Each phase restarts pods (config checksum annotations change) and re-runs the join Job,
which authenticates itself accordingly (`AUTH_INFLUX` for the data API,
`influxd-ctl -auth-type jwt -secret <meta-internal-shared-secret>` for the meta API).

Facts verified on a live cluster at each phase:

- Phase 2 takes effect immediately: anonymous `/query` → `unable to parse
  authentication credentials`; `curl -u admin:<HTTP_ADMIN_PASSWORD>` works. `/ping`
  stays 204 unauthenticated (liveness-friendly).
- `influxd-ctl` without credentials fails with `unable to parse authentication
  credentials` once phase 3 is on; with `-auth-type jwt -secret
  <INTERNAL_SHARED_SECRET>` it works again. The JWT username claim is empty, which the
  meta handler verifies against the *internal* secret.
- Phase 2/3 are independently reversible upgrades — but each one costs pod restarts,
  so treat them like any config change.

With auth on, take passwords from the Secret rather than copying them into commands or
values files:

```bash
kubectl -n <namespace> get secret influxdb-cluster-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Databases and Replication Factor

`cluster.databases` maps name → replication factor (1..`data.replicas`, validated at
render). The Job creates missing databases with `WITH REPLICATION <n>`; retention
policies get chart defaults (`autogen`, infinite).

> **Warning:** the Job never *changes* an existing database. Flipping `mydb: 2` to
> `mydb: 3` in values logs "exists" and does nothing. Apply it explicitly:

```bash
kubectl -n <namespace> exec influxdb-cluster-data-0 -- \
  curl -sS --data-urlencode \
  'q=ALTER RETENTION POLICY autogen ON mydb REPLICATION 3' 'http://localhost:8086/query'
```

Replication is per-database: a factor of 1 means losing one data node loses that
database's shards until copies are rebalanced. `SHOW RETENTION POLICIES ON mydb`
(inspect the `replicaN` column) is the source of truth.

Continuous queries, CQs, users beyond the admin: run their InfluxQL through the data
Service after the release is up (the same phases/credentials apply).

---

## Scaling

**Data nodes out** is a one-liner — the post-upgrade hook registers the new ordinal
only (verified live: 2 → 3, `SHOW SERVERS` then lists `data-2` without touching
`data-0/1`):

```bash
helm upgrade influx chart -n <namespace> -f chart/values.local.yaml --set data.replicas=3
```

Shard copies for new nodes come from the cluster's own rebalancing after the node
joins.

**Data nodes down** is NOT symmetric — do `helm upgrade --set data.replicas=2` AND
remove the departed address from the ledger first, otherwise the meta store keeps it as
a phantom member (this exact drift happened during development). Drain, then:

```bash
kubectl -n <namespace> exec influxdb-cluster-meta-0 -- \
  influxd-ctl -bind localhost:8091 remove-data influxdb-cluster-data-2.influxdb-cluster-data-headless.<namespace>.svc.cluster.local:8088
```

Then run the (`--set data.replicas=2`) upgrade and confirm it no longer appears in
`influxd-ctl show`.

**Meta nodes** follow raft rules: 3 → 5 is `--set meta.replicas=5` (hook runs
`add-meta` for 3 and 4). Meta scale-down additionally drains raft membership of the
two survivors' peers first (`remove-meta` for the old address); below 3 meta nodes
there is no room to lose one.

---

## Restart Semantics

- **Pod deleted (rollout, eviction, drain):** the new pod gets the same name, same PVC,
  same advertised hostname. Meta nodes replay raft from their PVC; data nodes reload
  their meta-client list from `<mountPath>/meta/client.json`. No re-registration needed
  and the hook Job (which just lists `show`) confirms members and exits. Verified by
  deleting a joined data pod mid-cluster: rejoined, kept writing, data queryable again.
- **`helm uninstall` + reinstall, same values/names:** the StatefulSet's
  `persistentVolumeClaimRetentionPolicy` (chart renders it from
  `persistence.reclaimPolicy`, default `Retain`) keeps PVCs; the reinstall reattaches
  and the raft store + shards come back (tested). `helm rollback` likewise restores
  config; data never belonged to the release object.
- **PVC survives but names change** (different release name / namespace /
  `fullnameOverride`): pods advertise NEW hostnames while the raft store still knows
  only OLD ones. `influxd-ctl add-meta` replies `... is a member of another cluster`,
  and NO amount of retrying helps — it is a data-plane decision (see next section).

---

## Probes

`probeMode` per node type per probe: `tcp` (default), `http` (GET `/ping`), `none`.

The HTTP probes look tempting and are a bootstrap deadlock — `/ping` is a
*cluster-state* read, not a liveness read:

- meta `/ping` body is empty while there is **no leader**, pods stay NotReady, and the
  join Job's `wait_port` was built not to trust readiness for exactly this reason
- data `/ping` is one of the auth-checked endpoints: it answers **503**
  (`no leader`) before the node has joined — the image itself ships a docker-compose
  healthcheck that does the very same `curl -f /ping || exit 1` *only after* joining

So HTTP `/ping` probes gate membership on membership. Keep `tcp` (port open = process
alive) and use `helm test` / `influxd-ctl show` for cluster-state assertions. That is
also why the data readiness probes answer Ready the moment the port opens: Ready means
"can serve requests", joined-or-not the node forwards — which is the correct client
signal. `startup` uses the (mode-portable) tcp form with a generous budget so slow
volume provisioning does not trip liveness.

---

## Changing Ports or Names

The addresses registered via `influxd-ctl` are `<pod-FQDN>:<port>`. Changing
`ports.metaAPI`, `ports.metaRaft`, `ports.dataHTTP`, `ports.dataTCP`,
`fullnameOverride`, `nameOverride`, `namespaceOverride`, or `clusterDomain`
after the first join turns every node's advertised address into something raft has
never seen — `add-*` calls then answer **"is a member of another cluster"**, which is
this fork's exact message for a membership conflict (`services/meta/handler.go`).

Escalating repairs, cheapest first:

1. **Undo the value change** (`helm rollback` or revert values.local.yaml). The
   restarts re-adopt the existing addresses; the raft store is untouched.
2. **Replace members one at a time** — meta: `remove-meta <old-addr>` for one node,
   let quorum settle, delete that pod so it recreates with the new address, and the
   join hook adds it back. Repeat per node. Data: `remove-data`, verify shard moves,
   then the pod.
3. **Rebuild the cluster** — last resort, and a fork-specific point: `influxd-ctl
   leave-meta` can *not* be used to shrink below a majority here — its code comment
   says *"leave-meta command is NOT ALLOWED for removal meta nodes that could be the
   majority choice"* — so a sub-quorum you cannot reach means restoring from backup
   (see [Backup and Restore](#backup-and-restore)), not improvising.

---

## Backup and Restore

No external backup tooling: **snapshot the PVCs through your storage driver** (CSI
VolumeSnapshot, `kubectl cp` for the tiny meta stores), keeping each PVC name ↔ pod
ordinal mapping intact because the recorded addresses are those very names.

Backup set per release (verified names):

| Volume | Path inside | Anything special |
| ------ | ----------- | ---------------- |
| meta PVC × `meta.replicas` | `<mountPath>/meta` | raft store; include EVERY ordinal, losing a majority is unrecoverable |
| data PVC × `data.replicas` | `<mountPath>/data`, `/wal` | shards; WAL may be incomplete for the live node — normal |

Take meta + data snapshots close together (membership drifts otherwise), and stop
writes during the window via your own proxy/leader drain.

Also periodic logical dumps while running — they restore through the normal write
path instead of rolling disks back:

```bash
kubectl -n <namespace> exec influxdb-cluster-data-0 -- \
  influx_inspect export -database mydb -compress -out /var/lib/influxdb/mydb.gz
kubectl -n <namespace> cp influxdb-cluster-data-0:/var/lib/influxdb/mydb.gz ./mydb-$(date +%F).gz
# restore (after the cluster is up and an empty `mydb` exists): influx -import with
# the dump, into the data Service URL
```

Restore = recreate the release with byte-identical identity values (`fullnameOverride`,
namespace, ports), PVC names pre-created from snapshots; the join hook then re-adopts
everything that matches.

---

## Uninstall

```bash
helm uninstall influx -n <namespace>
kubectl delete pvc --all -n <namespace>   # ONLY when the data is disposable
```

---

## Troubleshooting

Symptom first; each item is behavior observed on a real cluster or in the fork's code.

### Operator console

`influxd-ctl` is the cluster-management CLI and lives only in the **meta** pod; the
`influx` InfluxQL CLI lives only in the **data** pod (verified against both images):

```bash
# cluster membership (the ledger)
kubectl -n <namespace> exec -it influxdb-cluster-meta-0 -- \
  influxd-ctl -bind localhost:8091 show

# InfluxQL, from a data pod (or add -username/-password once phase 2 is on)
kubectl -n <namespace> exec -it influxdb-cluster-data-0 -- \
  influx -host localhost -execute 'SHOW SERVERS'

# one-off query without a tty — the query API needs no CLI at all
kubectl -n <namespace> exec influxdb-cluster-data-0 -- \
  curl -sS --data-urlencode 'q=<INFLUXQL>' 'http://localhost:8086/query'
```

### Join Job never reaches meta nodes

`meta node ... never answered on 300s` = pods up but even the port never opened:
check the meta PVCs (Pending? provisioner errors in `kubectl describe pvc`) and
`kubectl logs influxdb-cluster-meta-0`. Wording of the message covers the
headless-Service DNS case; `nslookup influxdb-cluster-meta-0.influxdb-cluster-meta-headless.<ns>.svc.cluster.local`
from a debug pod isolates DNS.

### `add-meta` says `is a member of another cluster`

(host, port) is registered with raft but pointed elsewhere: stale store, renamed
identity, or a port collision. Follow
[Changing Ports or Names](#changing-ports-or-names); retrying the Job cannot fix it.

### `helm test` fails immediately after install

The test waits up to 5 minutes for a joined data node, so a failure usually means the
join itself failed — read [Join Job never reaches meta nodes](#join-job-never-reaches-meta-nodes)
first. `{"error":"database name required"}` in its logs is not a cluster failure: a
`/query` without a `db` parameter and without a fully-qualified measurement is answered
that way (the test itself passes `db=`; it is the shape to expect from your own clients).

### Data pods CrashLoopBackOff on a fresh install

`data.env` entries named `INFLUXDB_DB`, `INFLUXDB_ADMIN_USER`, `INFLUXDB_ADMIN_PASSWORD`,
`INFLUXDB_USER`, `INFLUXDB_READ_USER` or `INFLUXDB_WRITE_USER` make the image's OSS
`/init-influxdb.sh` start a throwaway **standalone** influxd over the cluster data
directory before the real process starts (see
[How the Cluster Forms → Seeding quirks](#3-seeding-quirks-that-bit-during-development)
for why that path cannot work here). The chart rejects those names at render time; if
you reach this state through `data.envFrom`, remove them from that Secret.

### Phantom `data-N` in `influxd-ctl show` after scaling down

Expected: scale-down ≠ unregistration. `remove-data` (see [Scaling](#scaling)), then
upgrade.

### Nothing joined after a fresh install

Check `helm test` output, then `NOTES.txt` (`helm get notes influx -n <namespace>`): if
`cluster.joiner.enabled false` printed, there are manual instructions in that NOTES
block; otherwise examine the Job (its logs disappear on success unless
`hook-succeeded` was removed).

### Rotated secret has no effect

The chart mounts secrets as `secretKeyRef` environment variables and its pod-template
checksum annotation covers the **ConfigMaps** only, so editing a Secret's value does not
restart anything — nodes keep the old value from process start, and env vars are read
once. Apply a rotation with a deliberate rollout:

```bash
kubectl -n <namespace> rollout restart statefulset/influxdb-cluster-meta statefulset/influxdb-cluster-data
kubectl -n <namespace> rollout status  statefulset/influxdb-cluster-meta
```

Roll meta one pod at a time is NOT required (raft keeps quorum through the default
`updateStrategy: RollingUpdate`), but do it while `influxd-ctl show` reports a full peer
set. If you rotated only one of the two values in the meta Secret, phase 3 breaks with
`unable to parse authentication credentials` from the Job — both flags
(`sharedSecretKey`, `internalSharedSecretKey`) must describe the same Secret.

### Pods come back NotReady / cluster looks empty after a restore

Names drifted: the PVCs came back but the pods advertise addresses raft has never seen.
`influxd-ctl show` will list the OLD hostnames; `SHOW SERVERS` from a data pod will list
the NEW ones (empty). There is no in-place fix — see
[Changing Ports or Names](#changing-ports-or-names) and restore from a matching backup.

---

## References

- Upstream project: <https://github.com/chengshiwen/influxdb-cluster> (wiki:
  cluster-management commands incl. `add-meta`/`add-data` semantics)
- Images: `docker.io/chengshiwen/influxdb:<tag>-meta` / `-data` (Docker Hub `chengshiwen/influxdb`)
- Upstream Helm chart for comparison:
  <https://github.com/influxtsdb/helm-charts> `charts/influxdb-cluster`
- Auth semantics read from source: `services/meta/` (HTTP handler, `leave-meta`
  majority guard), `services/httpd/` (`/ping` auth + `no leader`) in the upstream repo
