# CloudNativePG

Operator installed with Helm in `cnpg-system`, each PostgreSQL cluster as its own `Cluster`
CR in `cnpg`. Everything below was run on the single-node k3s box (`wnp-w92575`, 8 CPU
allocatable) and the outputs are real.

## Table of Contents

- [Files](#files)
- [Install](#install)
- [Cluster CR](#cluster-cr)
- [Node Constraints](#node-constraints)
- [Connecting](#connecting)
- [pgcat](#pgcat)
- [Operations](#operations)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)

---

## Files

| File | Description |
| ---- | ----------- |
| `values.yaml` | **Operator** chart overrides: image tag 1.30.2 pinned, `replicaCount: 2`, `crds.create: true`, `config.clusterWide: true` |
| `default-values.yaml` | `helm show values` dump of chart 0.29.2, reference only — never pass it to `-f` |
| `example/db-secret.yaml` | `kubernetes.io/basic-auth` Secret consumed by `bootstrap.initdb.secret`. Plaintext password, tracked in git |
| `example/pg-cluster.yaml` | The `Cluster` CR: instances, storage, tuning, the `podSecurityContext` this node needs |
| `pgcat/pgcat-configmap.yaml` | `pgcat.toml` **template** (tokens, no passwords). Server list = `<cluster>-rw` + `<cluster>-ro`, never needs rewriting |
| `pgcat/pgcat-deployment.yaml` | pgcat Deployment: `sed`-renders the template from Secret env vars into an `emptyDir`, then `exec pgcat` |
| `pgcat/pgcat-service.yaml` | `pgcat` ClusterIP: `6432` clients, `9930` metrics |

Prerequisites: Helm 3+, namespace `cnpg` (nothing creates it), free CPU **requests** on the
node, StorageClass `csi-s3-block`.

> **Warning:** not the cluster default `csi-s3`. Same provisioner but `mounter: rclone` with
> `usePrefix: true`, so every claim resolves to one object path and provisioning dies with
> `AlreadyExists: Volume with the same name: … but with smaller size already exist`.

---

## Install

```bash
# 1. operator
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.2 \
  --namespace cnpg-system --create-namespace -f postgresql/CloudNativePG/values.yaml

# 2. namespace + bootstrap Secret BEFORE the Cluster: initdb waits for it and the job fails without it
kubectl create namespace cnpg
kubectl apply -f postgresql/CloudNativePG/example/db-secret.yaml

# 3. the database cluster
kubectl apply -f postgresql/CloudNativePG/example/pg-cluster.yaml
```

```bash
kubectl -n cnpg get clusters.postgresql.cnpg.io my-postgres-prod
# NAME               AGE   INSTANCES   READY   STATUS                     PRIMARY
# my-postgres-prod   48m   3           3       Cluster in healthy state   my-postgres-prod-1
```

Bootstrap order: Job `<cluster>-1-initdb` → instance 1 Ready → Job `<cluster>-N-join`
(`pg_basebackup`) per replica → its pod. Expect minutes on `csi-s3-block`.

`crds.create: true` installs the 11 CRDs **on first install only**; `helm upgrade` does not
touch them. Trust `kubectl explain clusters.postgresql.cnpg.io.spec.<field>` over any blog.

Verify what no status field shows:

```bash
PRIMARY=$(kubectl -n cnpg get cluster my-postgres-prod -o jsonpath='{.status.currentPrimary}')
kubectl -n cnpg exec $PRIMARY -c postgres -- psql -U postgres -Atc \
  "select application_name||' '||state||' '||sync_state from pg_stat_replication"
# my-postgres-prod-1 streaming async
# my-postgres-prod-2 streaming async

kubectl -n cnpg exec $PRIMARY -c postgres -- psql -U postgres -Atc "CHECKPOINT"  # AppArmor kills this
kubectl -n cnpg get endpointslices -L cnpg.io/cluster   # -rw one address, -ro the standbys
```

`async` = default `synchronous_commit`: a primary lost right after commit can lose that
commit. Raise `minSyncReplicas`/`maxSyncReplicas` if that is not acceptable.

---

## Cluster CR

| Parameter | Value here | Why |
| --------- | ---------- | --- |
| `spec.instances` | `3` | Three pods, three PVC pairs — survives pod/process failure, **not** node failure |
| `spec.imageName` | `ghcr.io/cloudnative-pg/postgresql:17.2` | Pinned; the operator never moves a major version by itself |
| `spec.bootstrap.initdb` | `app_db` / owner `app_user` / `my-db-secret` | Creates the app role and db during initdb |
| `spec.resources.requests` | `cpu: 10m`, `memory: 2Gi` | 10m only because the node had no request budget left, see [Node Constraints](#node-constraints) |
| `spec.storage` / `spec.walStorage` | `csi-s3-block` 50Gi / 10Gi | Separate WAL device; makes **two PVCs per instance**: `<cluster>-N` and `-wal` |
| `spec.postgresql.parameters` | `max_connections: 200`, `shared_buffers: 1GB`, `work_mem: 16MB` | `wal_log_hints` is on here, which `pg_rewind` after a failover needs |
| `spec.affinity.enablePodAntiAffinity` | `false` | CRD text: the operator adds anti-affinity "unless this field is explicitly set to false", with `topologyKey: kubernetes.io/hostname` — on one node the other replicas have nowhere to go |
| `spec.podSecurityContext` | Unconfined + uid/gid 26 + `fsGroup: 26` | Required here, and it **replaces** the operator default |
| `spec.monitoring.enablePodMonitor` | `true` | Deprecated and useless without `monitoring.coreos.com` CRDs: the operator logs `PodMonitor CRD not present` every reconcile. Set `false` |

Fields that do **not** exist in 1.30.2 despite looking obvious: `spec.serviceOverrides`,
`spec.restart`. `spec.enableSuperuserAccess` and `spec.primaryUpdateMethod`
(`switchover`\|`restart`) are top-level.

---

## Node Constraints

### AppArmor denies every `signal`

containerd 2.3.4 applies the generated `cri-containerd.apparmor.d` profile in **enforce** to
every pod, and it has no `signal` rules — `kill()` between two processes of the *same*
container returns EPERM. PostgreSQL runs on those signals: it prints `database system is ready
to accept connections`, then dies.

```bash
kubectl -n cnpg exec my-postgres-prod-1 -c postgres -- cat /proc/1/attr/current
# unconfined                                        <- works
# cri-containerd.apparmor.d//&unconfined (enforce)  <- Postgres will not work
```

Workaround in the CR: `spec.podSecurityContext.appArmorProfile.type: Unconfined`. The real fix
is node-wide: containerd's `default_app_armor_profile` in `/etc/rancher/k3s/config.yaml`.

### `spec.podSecurityContext` replaces, it does not merge

Repeat the whole operator default, especially `fsGroup`:

```yaml
spec:
  podSecurityContext:
    appArmorProfile: {type: Unconfined}
    runAsUser: 26          # the postgres user in the CNPG image
    runAsGroup: 26
    runAsNonRoot: true
    fsGroup: 26
    seccompProfile: {type: RuntimeDefault}
```

> **Warning:** drop `fsGroup: 26` and instance 1 keeps working (volume already chowned) while
> every **joining replica** loops on `pg_basebackup: error: could not create directory
> "/var/lib/postgresql/data/pgdata": Permission denied` — looks like replication, is
> `securityContext`. Use `podSecurityContext` (pod level), not `securityContext` (container
> level), which silently replaces the operator's hardened container defaults.

### CPU *requests* are exhausted, not CPU

The node was at 7990m/8000m requested, so a pod asking 100m was rejected with
`1 Insufficient cpu` on an otherwise idle node. Scheduling compares requests:

```bash
kubectl describe node wnp-w92575 | grep -A6 'Allocated resources'
```

`postgresql/sothanav-ha-pg` was lowered to `requests.cpu: 200m` per pod (chart default 500m)
to free 900m; this cluster asks 10m per instance. Limits untouched, pods still burst.

---

## Connecting

| Service | Selects | Use |
| ------- | ------- | --- |
| `<cluster>-rw` | `cnpg.io/instanceRole: primary` | writes |
| `<cluster>-ro` | `cnpg.io/instanceRole: replica` | reads |
| `<cluster>-r` | `cnpg.io/podRole: instance` | any instance. A normal ClusterIP, **not** headless — `<pod>.<cluster>-r.cnpg.svc` does not resolve |

```bash
psql "host=my-postgres-prod-rw.cnpg.svc port=5432 dbname=app_db user=app_user"   # password from my-db-secret
kubectl -n cnpg exec -it my-postgres-prod-1 -c postgres -- psql -U postgres      # socket, no password
```

`postgres` is not reachable over TCP: `spec.enableSuperuserAccess` is off, so no
`<cluster>-superuser` Secret exists.

> **Warning:** those three Services are operator-owned (`cnpg.io/lastAppliedSpec` records what
> the operator wrote). Hand-editing one — `-rw` to `LoadBalancer`, `port: 5433` — breaks
> replicas, which find the primary at `<cluster>-rw:5432`, and the operator answers with
> failovers. Publish your own Service with `cnpg.io/cluster` + `cnpg.io/instanceRole: primary`
> selectors instead.

---

## pgcat

One client endpoint that routes by SQL: `SELECT` → standby, everything else → primary, on
`pgcat.cnpg.svc:6432`. The operator's own `Pooler` CR is PgBouncer, which does not parse SQL —
it publishes two Services and the client picks.

No role-sync needed (unlike `postgresql/sothanav-ha-pg`): `-rw`/`-ro` already follow the
primary through a failover, so the server list is two stable hostnames and the only dynamic
step is substituting passwords from Secret env vars. Tokens in the template are substituted by
a global string replace — never spell one inside a comment.

```bash
# admin console account, kept out of the repo
kubectl -n cnpg create secret generic pgcat-admin-secret \
  --from-literal=username=pgcatadmin --from-literal=password="$(openssl rand -hex 16)"

kubectl apply -f postgresql/CloudNativePG/pgcat/
kubectl -n cnpg get deploy -l app.kubernetes.io/name=pgcat        # pgcat  2/2
```

Verified: reads answered by a standby (`inet_server_addr()` + `pg_is_in_recovery()`), writes on
the primary and replicated to both standbys, 80/80 queries ok in a soak, and the exporter
agrees (`/metrics` only, `/` and `/prometheus` 404):

```bash
kubectl -n cnpg port-forward svc/pgcat 19930:9930 &
curl -s http://127.0.0.1:19930/metrics | grep pgcat_servers_query_count
# {…host="my-postgres-prod-ro",role="replica"…} 102
# {…host="my-postgres-prod-rw",role="primary"…}  20
```

Console — answers only for a database that is **not** a pool name:

```bash
psql -h pgcat -p 6432 -U pgcatadmin -d pgcat -c 'show databases'
# app_db_shard_0_primary   |my-postgres-prod-rw|5432|app_db|app_user|30|…
# app_db_shard_0_replica_0 |my-postgres-prod-ro|5432|app_db|app_user|30|…
```

| Limit | Why |
| ----- | --- |
| Reads are not spread evenly over the standbys | `-ro` is one hostname; each pgcat pod holds a pooled connection to whichever standby kube-proxy picked. `load_balancing_mode = "random"` has nothing to choose between. Spread grows with `replicas`. Per-pod balancing needs per-pod DNS, which this cluster does not publish |
| No read-your-writes: `ERROR: relation "…" does not exist` right after the `CREATE TABLE` | The read went to a standby that has not replayed yet. Use `<cluster>-rw` for that statement |
| `SET` (e.g. `search_path`), `LISTEN`, advisory locks, prepared statements do not survive | `pool_mode = "transaction"` |
| Reads never fall back to the primary | `primary_reads_enabled = false`; set `true` if reads should survive zero standbys |

> **Warning:** `pool_size: 30` is per replica **and** per user — `replicas: 2` means 60 backend
> connections out of `max_connections: 200`, shared with the operator's own connections. The
> console (`show pools`) and `pg_stat_activity` both show live usage.

pgcat needs **no** AppArmor override: the profile only breaks fork-and-signal, and the `pg-ha`
pgcat pod has run 19h+ under the enforced profile.

```bash
kubectl -n cnpg scale deploy/pgcat --replicas=3        # scale this pooler
# the pg-ha pooler goes through Helm (pgcat.replicas in values.local.yaml), or the next
# upgrade resets it to the chart default of 1
kubectl -n cnpg delete -f postgresql/CloudNativePG/pgcat/   # uninstall; nothing else to clean
```

---

## Operations

```bash
# the `cluster` shortname is ambiguous across groups — use the FQN
kubectl get clusters.postgresql.cnpg.io -A

# only the operator leader logs
LEADER=$(kubectl -n cnpg-system get lease db9c8771.cnpg.io -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1)
kubectl -n cnpg-system logs $LEADER --tail=200 | grep my-postgres-prod

# the operator's own view
kubectl -n cnpg get cluster my-postgres-prod \
  -o jsonpath='{.status.instanceNames} {.status.initializingPVC} {.status.jobCount}{"\n"}'

# scale: newest instance is added/removed; PVCs are separate objects, check them either way
kubectl -n cnpg patch cluster my-postgres-prod --type=merge -p '{"spec":{"instances":2}}'
```

Replication lag — compare LSNs. `now() - pg_last_xact_replay_timestamp()` lies when the cluster
is idle: an idle, perfectly caught-up replica reports ten minutes.

```bash
PRIMARY=$(kubectl -n cnpg get cluster my-postgres-prod -o jsonpath='{.status.currentPrimary}')
kubectl -n cnpg exec $PRIMARY -c postgres -- psql -U postgres -Atc "select pg_current_wal_lsn()"
kubectl -n cnpg exec my-postgres-prod-1 -c postgres -- psql -U postgres -Atc "select pg_last_wal_replay_lsn()"
kubectl -n cnpg exec $PRIMARY -c postgres -- psql -U postgres -Atc \
  "select application_name,state,sync_state from pg_stat_replication"   # the authority
```

A deliberate **switchover** (`kubectl cnpg promote`) needs the plugin, which is not installed
here. Deleting the primary pod is a **failover**: it recovers, but the write endpoint moves
without asking. Pod-template changes only apply on re-creation; on a crash-looping instance
`kubectl -n cnpg delete pod <pod>` is the fast equivalent.

---

## Uninstall

```bash
kubectl delete cluster my-postgres-prod -n cnpg
kubectl -n cnpg get pvc -l cnpg.io/cluster=my-postgres-prod   # still there, on purpose

helm uninstall cnpg -n cnpg-system
kubectl get crd | grep postgresql.cnpg.io                     # still there too
```

> **Warning:** `csi-s3-block` has `reclaimPolicy: Delete` — deleting a PVC destroys the volume
> with no way back. And deleting a CRD deletes every `Cluster`/`Backup`/`Pooler` in the cluster;
> `helm uninstall` never removes CRDs on its own.

---

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| One pod `Pending`, nothing else Ready | Bootstrap never finished — instance 1 is not Ready so replicas are never created. Diagnose that pod |
| `FailedScheduling: pod has unbound immediate PersistentVolumeClaims` while the PVCs are `Bound`, or a `Pending` pod with **no** event at all | Stale scheduler verdict (the operator re-created the PVC during a failed initdb). Delete the pod — its Job re-creates it — and read the *new* event |
| `FailedScheduling: 1 Insufficient cpu. No preemption victims found` | Node CPU **requests** are full, see [Node Constraints](#node-constraints) |
| A second replica `Pending` with no cluster-level error | Default anti-affinity is per hostname. One node needs `spec.affinity.enablePodAntiAffinity: false` |
| CrashLoop, log ends `FATAL: could not signal for checkpoint: Permission denied` → `startup process (PID n) exited with exit code 1`; initdb Job adds `pg_ctl: could not send stop signal: Permission denied` | AppArmor. `cat /proc/1/attr/current` confirms; set `podSecurityContext.appArmorProfile.type: Unconfined` **with the whole default block**, then delete the pod |
| Joining replica loops `pg_basebackup: … "/var/lib/postgresql/data/pgdata": Permission denied`, instance 1 healthy | `fsGroup` missing from `podSecurityContext` |
| Operator repeats `Selected PVC is not ready yet, waiting for 1 second`, PVC annotated `cnpg.io/pvcStatus: initializing`, no `-join` Job, and lowering `spec.instances` changes nothing | The reconciler returns before job creation *and* before scale-down. Only deleting that instance's PVCs clears it — after proving they are empty (`du -sh` in a throwaway pod: a failed join writes nothing) and remembering `reclaimPolicy: Delete` |
| Hand-edited `-rw` (`LoadBalancer`, `port: 5433`) takes the cluster down in stages: `Waiting for the new primary to be available`, `0/1` replicas, `Event: FailingOver … Current primary isn't healthy`, operator spam `Cannot extract Pod status … 500` | Replicas reach the primary through `<cluster>-rw:5432`; changing the port orphans them. Diagnose from a replica pod: `pg_isready -h <cluster>-rw -p 5432` (no response) vs `-p 5433` (accepting). Put `port: 5432` back, or revert the Service and publish your own |
| After a failover the demoted old primary won't join: `replication slot "_cnpg_<cluster>_N" cannot be advanced`, `Refusing to restore future timeline history file`, `invalid record length … got 0`. It can even be `1/1 Ready` with **zero** rows in `pg_stat_replication`, serving stale reads through `-ro` | Timelines diverged; a restart cannot fix it. Delete that instance's pod **and** both PVCs — the operator re-provisions and re-clones in about a minute. Safe only because it is a replica |
| `Cannot extract Pod status … 500` in the operator log | Consequence, not cause: an instance's PostgreSQL is down. The two rows above produce it |
| `fe_sendauth: no password supplied` for `-rw -U postgres` while the same command works in the pod | Socket = trust, TCP = scram. Use `app_user`, or `PGPASSWORD` |
| `AlreadyExists: Volume with the same name … already exist`, PVC `Pending` | StorageClass is `csi-s3` (rclone, shared prefix). Use `csi-s3-block` |
| 50Gi full, PVC won't grow | `csi-s3-block` has `allowVolumeExpansion: false` — patch the StorageClass, then the PVC |
| `strict decoding error: unknown field "spec.appArmorProfile"` | It is `spec.securityContext.appArmorProfile` on a pod, not `spec.appArmorProfile` |
| pgcat client: `FATAL: could not get connection from the pool - AllServersDown`, pod `1/1 Running` | Both servers banned after broken pooled connections: log shows `Failed health check on instance …` → `Banning instance …` → `Unbanning all replicas.` (`ban_time = 10`). A failover looks identical and clients recover unaided; if it never clears, `show databases` is pointing at the wrong host |
| pgcat console: `FATAL: No pool configured for database: "app_db", user: "pgcatadmin"` | Expected — connect with a database that is not a pool name (`-d pgcat`) |
| pgcat ignores `SET`, or misses a just-created table | Transaction pooling and standby lag — see [pgcat](#pgcat) |
