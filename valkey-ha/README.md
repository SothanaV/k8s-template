# Valkey 8 HA (Sentinel + HAProxy) — self-contained chart

Kubernetes port of `docker-template/valkey/ha-valkey`: a Valkey replication cluster with a
Sentinel sidecar per node and an HAProxy pair exposing role-routed R/W and R/O endpoints.

## Table of Contents

- [Architecture](#architecture)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [Credentials](#credentials)
- [Installation](#installation)
- [Values Reference](#values-reference)
- [Connecting](#connecting)
- [How the master endpoint follows failover](#how-the-master-endpoint-follows-failover)
- [Failover drill](#failover-drill)
- [Verifying the cluster](#verifying-the-cluster)
- [Scaling and storage](#scaling-and-storage)
- [Troubleshooting](#troubleshooting)
- [Uninstall and rollback](#uninstall-and-rollback)

---

## Architecture

```
clients ──► valkey-ha-haproxy        (Service, ClusterIP|LB|NodePort)
              │ :6379 R/W   :6380 R/O   :8404 /stats,/metrics
              ▼
            Deployment valkey-ha-haproxy ×2
              │ tcp-check AUTH + INFO replication:
              │ only the node answering role:master is UP on :6379
              ▼
   ┌────────────┬────────────┬────────────┐
   │ valkey-ha-0│ valkey-ha-1│ valkey-ha-2│   StatefulSet ×3 (PVC each)
   │ ├ valkey   │ ├ valkey   │ ├ valkey   │   :6379 data, one master + N-1 replicas
   │ └ sentinel │ └ sentinel │ └ sentinel │   :26379 quorum=2, failover automatic
   └────────────┴────────────┴────────────┘
        ▲            ▲            ▲
   Service valkey-ha-node-0 / -node-1 / -node-2 (one ClusterIP VIP per pod)
        ▲
   Service valkey-ha-headless (per-pod DNS for StatefulSet identity)
```

The compose→Kubernetes mapping, and the two rules the whole design follows:

| docker-compose | chart | why |
| -------------- | ----- | --- |
| `valkey-node-N` @ static `172.29.0.1x` | StatefulSet pod + **per-node ClusterIP Service** `valkey-ha-node-N` | a Service VIP survives pod rescheduling; a pod IP does not |
| `network_mode: service` sentinel | Sentinel sidecar container in the same pod | same shared network namespace as compose gave |
| `--replicaof 172.29.0.11` (hardcoded) | entrypoint discovers the live master at boot | a pod restarting after a failover must rejoin the NEW master, not revive itself |
| `sentinel monitor mymaster 172.29.0.11` | monitor target = live master's Service VIP, re-checked by a watchdog | raw Sentinel persists pod IPs after failover; pod IPs move |
| `haproxy-1/2`, tcp-check role detection | Deployment `valkey-ha-haproxy`, same tcp-checks | verbatim — this is what makes `:6379` follow failovers |

1. **Nothing durable addresses a pod IP.** Sentinel's state file, HAProxy's server list,
   and the entrypoints' boot decisions all speak per-node Service VIPs, which kube-proxy
   keeps pointing at the pod wherever it lands.
2. **The live cluster outranks memory.** Every boot asks `role:master` of the cluster
   first, Sentinel's memory second, `bootstrap.primaryOrdinal` last.

### Compose parity / differences

Same: 3 nodes + 3 sentinels + 2 active-active proxies, `appendonly yes`, requirepass on
data and Sentinel ports, R/W + R/O + stats ports, quorum 2, down-after 5s,
failover-timeout 10s, parallel-syncs 1, Redis Insight (off by default).

Different on purpose: no static IPs; master/replica role decided at boot instead of
baked into CLI args; passwords from a Secret (the compose placeholders are only the
values.yaml defaults for local use); the replica backend accepts `role:slave` **and**
`role:replica` because INFO wording differs across Valkey versions.

---

## Files

| File | Description |
| ---- | ----------- |
| `Chart.yaml`, `values.yaml`, `.helmignore` | chart metadata + all knobs, documented inline |
| `templates/statefulset.yaml` | the data pod: valkey + sentinel sidecar, probes, PVC template; also runs the values validator |
| `templates/service-nodes.yaml` | per-node ClusterIP Services (the stable VIPs) |
| `templates/service-headless.yaml` | StatefulSet governing Service, publishes not-ready pods |
| `templates/service-haproxy.yaml`, `templates/deployment-haproxy.yaml` | client endpoints + proxy (init container waits for all node PONGs) |
| `templates/configmap-scripts.yaml` | the pod scripts + `entrypoint-env.sh` generated from values |
| `templates/configmap-sentinel.yaml` | sentinel.conf template + `sentinel.extraConfig` tail |
| `templates/configmap-haproxy.yaml` | haproxy.cfg with servers/ports filled; **no secrets inside** |
| `templates/secret.yaml`, `pdb.yaml`, `serviceaccount.yaml`, `redis-insight.yaml`, `NOTES.txt`, `_helpers.tpl` | optional Secret, PodDisruptionBudgets, SA, GUI, post-install notes, helpers + validator |
| `files/scripts/valkey-entrypoint.sh` | master/replica decision at boot + background re-follow watcher |
| `files/scripts/sentinel-entrypoint.sh` | renders sentinel.conf, picks the monitor target, runs the watchdog |
| `files/scripts/common.sh` | shared shell: DNS resolve, role probe, `SENTINEL MONITOR` re-point |
| `files/sentinel.conf.tpl`, `files/haproxy.cfg.tpl` | config templates with `@TOKENS@` filled at pod start |

Commands below are relative to the **k8s-template repo root**.

---

## Prerequisites

- Kubernetes >= 1.25 (tested on k3s v1.36), Helm 3.x, kubectl
- A StorageClass that provisions RWO volumes — and **pass it explicitly** via
  `persistence.storageClass` when the cluster has more than one default (several
  clusters here do; see [Troubleshooting](#troubleshooting))
- Cluster DNS (kube-dns/CoreDNS) — the per-node Services are the cluster's addressing
  substrate
- No shared/ReadWriteMany storage: this is shared-nothing replication, exactly like the
  compose stack's three separate volumes

Single-node clusters work (all pods co-schedule); node-loss resistance obviously needs 3+
nodes.

---

## Credentials

Four values feed one Secret; the charset rule `[A-Za-z0-9._@:-]` is enforced at render
time (values are sed-substituted into sentinel.conf and land in HAProxy's
space-delimited `tcp-check send AUTH ...` line):

| value | Secret key | used by |
| ----- | ---------- | ------- |
| `auth.valkeyPassword` | `valkey-password` | `requirepass` + `masterauth` on :6379, Sentinel `auth-pass`, HAProxy tcp-checks |
| `auth.sentinelPassword` | `sentinel-password` | `requirepass` on :26379 |
| `haproxy.statsPassword` | `stats-password` | HAProxy `/stats` basic auth (user = `haproxy.statsUser`) |

Two modes:

```bash
# mode A (default): chart creates Secret "valkey-ha" from values
#   -> fine locally; the Secret is DELETED with the release
helm install valkey-ha valkey-ha/ -n valkey-ha --create-namespace

# mode B: pre-created Secret, chart renders none
kubectl -n valkey-ha create secret generic valkey-ha-secret \
  --from-literal=valkey-password="<VALKEY_PASSWORD>" \
  --from-literal=sentinel-password="<SENTINEL_PASSWORD>" \
  --from-literal=stats-password="<STATS_PASSWORD>"
helm install valkey-ha valkey-ha/ -n valkey-ha \
  --set auth.existingSecret=valkey-ha-secret
```

> **Warning:** with mode A, `helm uninstall` deletes the Secret — the data in surviving
> PVCs becomes unreachable without re-creating the same passwords. Use mode B for
> anything you plan to restore later.

> **Warning:** the values.yaml passwords are the compose template's public defaults.
> Override them (`--set` or a gitignored `values.local.yaml`) before real use.

---

## Installation

### 1. Preview

```bash
helm template valkey-ha valkey-ha/ -n valkey-ha --set persistence.storageClass=<STORAGE_CLASS> \
  | kubectl apply --dry-run=server --namespace valkey-ha -f -
```

### 2. Install

```bash
helm upgrade --install valkey-ha valkey-ha/ \
  -n valkey-ha --create-namespace \
  --set persistence.storageClass=<STORAGE_CLASS>
```

### 3. Watch the bootstrap

Pods come up strictly ordered (pod 0 Ready before pod 1 starts):

```bash
kubectl -n valkey-ha rollout status statefulset/valkey-ha
kubectl -n valkey-ha rollout status deploy/valkey-ha-haproxy
```

Expected output: `statefulset rolling update complete 3 pods...` then the deployment
rollout — HAProxy's init container only finishes once every node answers PONG.

### 4. Verify

```bash
kubectl -n valkey-ha get pods,pvc
kubectl -n valkey-ha logs valkey-ha-0 -c valkey | grep '\[valkey-ha\]'
kubectl -n valkey-ha logs valkey-ha-1 -c valkey | grep '\[valkey-ha\]'
```

Expected output (first install):

```
[valkey-ha] ... bootstrapping as master (ordinal 0 == bootstrap.primaryOrdinal)
[valkey-ha] ... live master: valkey-ha-node-0.valkey-ha.svc.cluster.local (10.43.x.x)
```

That second VIP is the node-0 Service, and it is what Sentinel persists — see
[failover](#how-the-master-endpoint-follows-failover).

---

## Values Reference

Only the knobs you are expected to touch; every field is commented in `values.yaml`.

| Parameter | Description | Default |
| ----------- | ----------- | ------- |
| `fullnameOverride` | name prefix; pinned because Sentinel persists the monitored address | `valkey-ha` |
| `replicas` | data pods = sentinels | `3` |
| `image.tag` | keep the Valkey major = `appVersion` | `8-alpine` |
| `auth.existingSecret` | use a pre-created Secret (see Credentials) | `""` |
| `auth.valkeyPassword` / `auth.sentinelPassword` | only when the chart creates the Secret | compose defaults |
| `valkey.config` | extra `--key value` server args, single-token values only | `{}` |
| `sentinel.quorum` | must be a majority of `replicas` | `2` |
| `sentinel.masterName` | the `mymaster` of the compose stack | `mymaster` |
| `sentinel.watchdogIntervalSeconds` | monitor-address self-heal cadence | `10` |
| `haproxy.enabled` | set false to talk to node Services directly | `true` |
| `haproxy.masterPort` / `replicaPort` / `statsPort` | R/W, R/O, stats endpoints | `6379` / `6380` / `8404` |
| `haproxy.service.type` | `ClusterIP` \| `LoadBalancer` \| `NodePort` (+`service.nodePorts.*`) | `ClusterIP` |
| `persistence.storageClass` | **set explicitly when the cluster has multiple default SCs** | `""` |
| `persistence.size` | per-pod PVC | `1Gi` |
| `podDisruptionBudget.valkey.minAvailable` | quorum guard during drains; must be < `replicas` | `2` |
| `nodeSelector` / `tolerations` / `affinity` / `topologySpreadConstraints` | valkey pod placement | `{}` / `[]` |
| `redisInsight.enabled` | GUI Deployment (+ optional `.ingress`) | `false` |

The validator fails the render (not the runtime) on: non-majority quorum,
`minAvailable >= replicas`, duplicate haproxy ports, password charset violations,
whitespace inside `valkey.config` values, `primaryOrdinal >= replicas`, NodePorts
outside 30000-32767.

---

## Connecting

| What | Address | Auth |
| ---- | ------- | ---- |
| application R/W | `valkey-ha-haproxy.<namespace>.svc:6379` | `valkey-password` |
| application read scaling | `valkey-ha-haproxy.<namespace>.svc:6380` | `valkey-password` |
| stats UI / Prometheus exporter | `...:8404/stats`, `/metrics` | `statsPassword` (exporter: none) |
| Sentinel clients (`redis-cli -s`, sentinel-aware libs) | `valkey-ha-node-<i>:26379` | `sentinel-password`, master name `mymaster` |
| direct node access (debug) | `valkey-ha-node-<i>:6379` | `valkey-password` — the role can flip after failover |

Applications only need the two haproxy ports: HAProxy learns roles from `INFO
replication` health checks, so plain clients get failover without Sentinel support.

```bash
# local check from outside the cluster
kubectl -n valkey-ha port-forward svc/valkey-ha-haproxy 6379:6379
redis-cli -a "<VALKEY_PASSWORD>" -p 6379 set hello world
```

---

## How the master endpoint follows failover

Three cooperating mechanisms, all verified live in the drill below:

1. **HAProxy** marks a backend server UP only when its tcp-check
   (`AUTH` → `INFO replication` → `role:master`) passes, with a 1s check interval. When
   a new master appears, the R/W endpoint moves in ~1-2 s. The R/O backend is the mirror
   (`role:slave|role:replica`), so during a failover a key momentarily isn't readable —
   clients retry.
2. **Boot-time discovery** ([`files/scripts/valkey-entrypoint.sh`](files/scripts/valkey-entrypoint.sh)):
   scan node Services for `role:master` → ask Sentinel memory (only when the pod has
   data) → bootstrap ordinal. A restarted pod can therefore never resurrect itself as a
   competing master while another node holds the role. A background watcher repeats the
   scan every 15 s for replicas whose link stayed down.
3. **Sentinel watchdog** ([`files/scripts/sentinel-entrypoint.sh`](files/scripts/sentinel-entrypoint.sh)):
   after its own failovers raw Sentinel rewrites its state with the promoted pod's *pod
   IP*. The watchdog verifies each pass that the monitored address still reports
   `role:master`; when it doesn't (pod rescheduled), it re-points via
   `SENTINEL REMOVE` + `SENTINEL MONITOR` + `SENTINEL SET` to the live master's Service
   VIP. This is the Kubernetes analogue of compose's static IPs doing the work.

---

## Failover drill

Both drills below were run on the deployed cluster with exactly these results.

### 1. Pod loss (master comes back fast — expect NO failover)

```bash
kubectl -n valkey-ha delete pod <master-pod>
```

If the pod returns faster than `down-after-milliseconds` (5 s by default), Sentinel
correctly skips the election and the endpoint never blanks. The restarted container
decides from Sentinel memory — expected log:

```
[valkey-ha] ... Sentinel names ME as master (10.43.x.x) — starting as master
```

### 2. Forced promotion (expect full role flip)

```bash
kubectl -n valkey-ha exec valkey-ha-1 -- valkey-cli -a "<SENTINEL_PASSWORD>" \
  -p 26379 sentinel failover mymaster
# within a couple of seconds:
kubectl -n valkey-ha exec valkey-ha-0 -- valkey-cli -a "<VALKEY_PASSWORD>" \
  -h valkey-ha-haproxy info replication | head -3
```

Expected: the new master answers `role:master` on the same haproxy endpoint; the demoted
master's log shows it following the new one (`master_host:` = new master's address)
because Sentinel reconfigures reachable old masters; writes through `:6379` keep
working and old keys are present (AOF + live replication, nothing lost in a clean
failover).

### 3. Kill the promoted master and keep it down

`kubectl delete pod` alone lets it return within seconds — usually before quorum
elects. With the highest ordinal as master (the state drill 2 leaves: `valkey-ha-2`):

```bash
kubectl -n valkey-ha delete pod valkey-ha-2
kubectl -n valkey-ha scale statefulset/valkey-ha --replicas=2   # hold it down
# remaining sentinels (2 of 3, quorum 2) elect the other replica; :6379 follows
kubectl -n valkey-ha scale statefulset/valkey-ha --replicas=3   # rejoins as replica
```

---

## Verifying the cluster

```bash
PW=$(kubectl -n valkey-ha get secret valkey-ha -o jsonpath='{.data.valkey-password}' | base64 -d)

# who is who
for i in 0 1 2; do kubectl -n valkey-ha exec valkey-ha-$i -- \
  valkey-cli --no-auth-warning -a "$PW" -h valkey-ha-node-$i.valkey-ha.svc.cluster.local \
  info replication | grep -E '^role:|^master_host'; done

# Sentinel consensus (run inside any pod's sentinel sidecar)
kubectl -n valkey-ha exec valkey-ha-0 -- valkey-cli --no-auth-warning -a "<SENTINEL_PASSWORD>" \
  -p 26379 info sentinel | grep master0
# expected: master0:name=mymaster,status=ok,address=<VIP or master address>:6379,slaves=2,sentinels=3

# endpoints: master endpoint must answer role:master exactly; R/O only slave
kubectl -n valkey-ha exec valkey-ha-0 -- valkey-cli --no-auth-warning -a "$PW" \
  -h valkey-ha-haproxy info replication | grep -E '^role:|^connected_slaves'
```

Healthy = exactly one `role:master`, both slaves pointing at the same `master_host`,
`status=ok`, endpoint roles consistent with the per-node probe.

---

## Scaling and storage

- `replicas` changes the StatefulSet and regenerates HAProxy's server list (the config
  checksum rolls the proxies). Keep `sentinel.quorum` a majority — the validator does
  this arithmetic for you.
- One RWO PVC per pod (`volumeClaimTemplates`, `data`); PVCs are never deleted by
  scaling down — scale back up re-attaches them.
- `podManagementPolicy: OrderedReady` is immutable; to switch, delete the StatefulSet
  with `--cascade=orphan` and re-apply.
- Drains: the valkey PDB (`minAvailable: 2`) blocks evictions that would drop the
  cluster below Sentinel majority. On a **single-node** cluster this means a
  `kubectl drain` of that node will not finish the valkey pod — expected, or lower
  `podDisruptionBudget.valkey.minAvailable`.

---

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| First PVC `Pending` forever | No default StorageClass resolution — several clusters here mark **two** SCs default (`csi-s3`, `local-path`); Kubernetes then resolves the empty `storageClassName` unpredictably (possibly the S3-backed one — slow and unintended). Always set `persistence.storageClass` explicitly |
| HAProxy pods stuck `Init:0/1` | The init container is waiting for every node to answer PONG — inspect `kubectl logs <haproxy-pod> -c wait-nodes` and the last valkey pod's logs; usually a valkey pod crashlooping or a password changed mid-life (Secret vs `values.yaml` disagreement) |
| `tcp-check` backends all DOWN after install | Wrong `valkey-password` in the Secret vs pods (role-routed checks authenticate). Both haproxy and pods read the same Secret — compare `kubectl get secret ... -o yaml` against pod env |
| Two masters after a disaster | `sentinel.quorum` below majority — impossible via this chart (validator) but possible after editing the rendered manifest; keep `quorum > replicas/2` |
| `helm install` fails: "podDisruptionBudget ... drain" message | `minAvailable >= replicas`; on 1 replica set `podDisruptionBudget.valkey.enabled=false` |
| A restarted pod's logs loop `waiting for DNS: valkey-ha-node-N...` | `fullnameOverride`/`namespaceOverride`/`clusterDomain` disagree with where the Services actually are — the VIPs must be resolvable from the pod |
| Sentinel logs keep saying `+switch-master` with stable topology | Transient while old sentinel/replica records age out after a failover (entries keyed by dead pod IPs expire); if it persists > 1 min, check for a second cluster sharing the same `fullnameOverride` in another namespace |
| Redis Insight pod CrashLoopBackOff | its PVC needs a provisionable StorageClass; or set `redisInsight.persistence.enabled=false` for throwaway use |

---

## Uninstall and rollback

```bash
helm history valkey-ha -n valkey-ha
helm rollback valkey-ha <REVISION> -n valkey-ha        # config rollback; PVCs untouched

helm uninstall valkey-ha -n valkey-ha                  # leaves PVCs (+ mode-A Secret) behind
kubectl -n valkey-ha delete pvc --all                  # ONLY when the data is disposable
kubectl delete ns valkey-ha
```

> **Warning:** `helm uninstall` + re-install with mode A restores pods against the
> leftover PVCs **with the old passwords**, while the re-created Secret carries whatever
> values you pass now — `requirepass` mismatch means every client and tcp-check fails.
> Either keep the Secret (`auth.existingSecret`) or pass the original passwords again.
