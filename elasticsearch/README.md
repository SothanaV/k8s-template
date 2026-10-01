# Elasticsearch (`production-es`)

Deploys the Elasticsearch cluster `production-es` in the `grafana` namespace
from the upstream `elastic/elasticsearch` chart. This cluster is the syslog
mirror target of `observe/syslog` (Fluent Bit `out_elasticsearch`).

## Table of Contents

- [Prerequisites](#prerequisites)
- [Topologies](#topologies)
- [File Reference](#file-reference)
- [Installation](#installation)
- [Rendered Object Names](#rendered-object-names)
- [Values Reference](#values-reference)
- [Integration with `observe/syslog`](#integration-with-observesyslog)
- [Verification](#verification)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Helm 3+ with the Elastic repo added:

```bash
helm repo add elastic https://helm.elastic.co
helm repo update
```

- The namespace, created once (also used by the Grafana stack, see
  `_deploy/README.md`):

```bash
kubectl create ns grafana
```

- Chart `elasticsearch-8.5.1` (Elasticsearch 8.5.1, image
  `docker.elastic.co/elasticsearch/elasticsearch:8.5.1`). Pin `--version 8.5.1`
  on every release so all node groups stay on the same app version.
- Worker nodes to satisfy the replica counts and anti-affinity below: `hard`
  puts one pod per node, so the master group alone needs 3 schedulable nodes.
- A `StorageClass` for the data PVCs: `values.yaml` asks for `longhorn`
  explicitly; `master-values.yaml` and `data-values.yaml` set none and use the
  cluster default.
- `vm.max_map_count` is raised by the chart's privileged
  `configure-sysctl` init container (`sysctlInitContainer.enabled: true`). If
  PodSecurity restrictions block privileged init containers, set
  `sysctlInitContainer.enabled: false` and tune the nodes yourself.

---

## Topologies

`clusterName: production-es` in all three files, so every file joins the same
cluster name. Pick **one** option per environment.

### Option A — all-in-one (`values.yaml`)

One node group of 3 nodes, each with `master + data + ingest`. Used for the
`es` release.

### Option B — dedicated master + data groups (production)

Two releases that form one cluster. Install masters first: data nodes seed
through `production-es-master-headless`, which only exists once the master
release is deployed. Because each group generates its own CA by default, both
release Secrets must share one certificate authority — see the last entry in
[Troubleshooting](#troubleshooting).

| Node group | Values file | Replicas | Anti-affinity | Roles | Heap | CPU req/lim | Mem req/lim | PVC |
| ---------- | ----------- | -------- | ------------- | ----- | ---- | ----------- | ----------- | --- |
| `master` | `master-values.yaml` | 3 | `hard` | `master` | `-Xmx2g -Xms2g` | `1000m` / `2000m` | `2Gi` / `4Gi` | 10Gi |
| `data` | `data-values.yaml` | 4 | `soft` | `data`, `ingest` | `-Xmx16g -Xms16g` | `4000m` / `8000m` | `8Gi` / `12Gi` | 50Gi |
| all-in-one | `values.yaml` | 3 | `hard` | `master`, `data`, `ingest` | `-Xmx4g -Xms4g` | `2000m` / `4000m` | `8Gi` / `8Gi` | 100Gi (`longhorn`) |

> **Warning:** Option A and Option B both use `nodeGroup: "master"` under the
> same `clusterName`, so they render the same StatefulSet
> (`production-es-master`), services, PDB (`production-es-master-pdb`) and
> Secrets. Never install both into the same namespace — only one release may own
> those names.

> **Warning:** `data-values.yaml` requests a `16g` heap against a `12Gi`
> container limit. Elasticsearch refuses to start when the heap exceeds the
> container memory, so lower `esJavaOpts` or raise the memory limit for the data
> group.

---

## File Reference

Paths relative to the repo root.

| File | Description |
| ---- | ----------- |
| `_deploy/elasticsearch/values.yaml` | All-in-one 3-node group (master + data + ingest), 100Gi `longhorn` PVCs |
| `_deploy/elasticsearch/master-values.yaml` | Dedicated master group, 3 replicas, hard anti-affinity |
| `_deploy/elasticsearch/data-values.yaml` | Dedicated data/ingest group, 4 replicas, soft anti-affinity |
| `_deploy/elasticsearch/README.md` | This file |
| `observe/syslog/README.md` | Consumer of this cluster (*Elasticsearch Mirror* section) |

---

## Installation

Run from `_deploy/elasticsearch/` so the relative `-f` paths resolve. Use
`helm upgrade -i` for both first installs and later changes; the StatefulSet
name comes from `clusterName`/`nodeGroup`, not the release name, so object names
stay stable when the release is re-created.

### Deploy the all-in-one cluster

```bash
helm upgrade -i es elastic/elasticsearch --version 8.5.1 -n grafana -f values.yaml
```

### Deploy the split cluster (production)

Masters first, and wait for them before adding data nodes — the data pods
restart repeatedly until they can seed the cluster.

```bash
helm upgrade -i es-master elastic/elasticsearch --version 8.5.1 -n grafana -f master-values.yaml
kubectl -n grafana rollout status statefulset/production-es-master
```

```bash
helm upgrade -i es-data elastic/elasticsearch --version 8.5.1 -n grafana -f data-values.yaml
```

> **Warning:** expect `helm upgrade` of the master group to take several minutes
> — pods start in parallel (`podManagementPolicy: Parallel`) but the readiness
> probe waits for `wait_for_status=green` against the local node.

---

## Rendered Object Names

Confirmed from `helm template` of chart 8.5.1 with these values files. Names are
built from `clusterName`/`nodeGroup`, so release names are cosmetic.

| Object | Master group | Data group |
| ------ | ------------ | ---------- |
| StatefulSet | `production-es-master` | `production-es-data` |
| Client Service (`ClusterIP`, 9200/9300) | `production-es-master` | `production-es-data` |
| Headless Service (discovery) | `production-es-master-headless` | `production-es-data-headless` |
| PDB (`maxUnavailable: 1`) | `production-es-master-pdb` | `production-es-data-pdb` |
| Credentials Secret (`username`, `password`) | `production-es-master-credentials` | `production-es-data-credentials` |
| TLS Secret (`ca.crt`, `tls.crt`, `tls.key`) | `production-es-master-certs` | `production-es-data-certs` |
| PVC template (per replica) | `production-es-master` | `production-es-data` |

---

## Values Reference

| Parameter | Description | `values.yaml` | `master-values.yaml` | `data-values.yaml` |
| --------- | ----------- | ------------- | -------------------- | ------------------ |
| `clusterName` | Cluster name; prefixes every object name | `production-es` | `production-es` | `production-es` |
| `nodeGroup` | Node group name; second name prefix, and the group other nodes seed through | `master` | `master` | `data` |
| `replicas` | Pods in the group | `3` | `3` | `4` |
| `antiAffinity` | `hard` = one pod per node, `soft` = best effort | `hard` | `hard` | `soft` |
| `roles` | Node roles (8.x syntax) | `master,data,ingest` | `master` | `data,ingest` |
| `esJavaOpts` | JVM heap — keep at ~50% of the container memory limit | `-Xmx4g -Xms4g` | `-Xmx2g -Xms2g` | `-Xmx16g -Xms16g` |
| `resources.requests.cpu` / `.limits.cpu` | CPU | `2000m` / `4000m` | `1000m` / `2000m` | `4000m` / `8000m` |
| `resources.requests.memory` / `.limits.memory` | Memory | `8Gi` / `8Gi` | `2Gi` / `4Gi` | `8Gi` / `12Gi` |
| `volumeClaimTemplate.accessModes` | Access mode | `ReadWriteOnce` | `ReadWriteOnce` | `ReadWriteOnce` |
| `volumeClaimTemplate.storageClassName` | StorageClass; unset = cluster default | `longhorn` | *(default SC)* | *(default SC)* |
| `volumeClaimTemplate.resources.requests.storage` | Per-node PVC size | `100Gi` | `10Gi` | `50Gi` |

Defaults that matter and are **not** set in these files:

| Parameter | Chart default | Effect here |
| --------- | ------------- | ----------- |
| `createCert` | `true` | Security is ON: `xpack.security.enabled=true`, TLS on HTTP and transport, one self-signed cert per node group (SANs cover `production-es-master*`) |
| `secret.enabled` | `true` | `elastic` password generated into `<uname>-credentials` and injected as `ELASTIC_PASSWORD` |
| `clusterHealthCheckParams` | `wait_for_status=green&timeout=1s` | Readiness probe; a single-node group can stay not-ready and block a rollout |
| `pdb.maxUnavailable` | `1` | One pod per group may be down at a time |
| `tests.enabled` | `true` | Adds a `helm test` pod per release |

---

## Integration with `observe/syslog`

The syslog pipeline mirrors every record into this cluster over HTTPS with CA
verification and basic auth (see `observe/syslog/README.md`, *Elasticsearch
Mirror*). It consumes the **master** group's objects:

| Consumer setting | Value | Requires |
| ---------------- | ----- | -------- |
| `elasticsearch.host` | `production-es-master.grafana.svc` | master group deployed (Option A release also names its group `master`) |
| `elasticsearch.port` | `9200` (HTTPS — `Tls On` in the Fluent Bit output) | `createCert: true` |
| `elasticsearch.auth.existingSecret` | `production-es-master-credentials` | `secret.enabled: true` (`username`/`password` keys) |
| `elasticsearch.tls.existingSecret` | `production-es-master-certs` (only `ca.crt` is projected) | `createCert: true` |

`secretKeyRef` cannot cross namespaces: deploying the syslog chart anywhere other
than `grafana` means copying those two Secrets first, or using
`--set elasticsearch.enabled=false`.

Retrieve the `elastic` password from the generated Secret — never commit it to
this repo:

```bash
kubectl -n grafana get secret production-es-master-credentials \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## Verification

```bash
kubectl -n grafana get pods,svc,pdb -l app=production-es-master
kubectl -n grafana get pods,svc,pdb -l app=production-es-data   # Option B only
```

PVCs carry no `app` label (`persistence.labels.enabled` is `false` in the chart),
so list them by name instead — each group owns `<uname>-<ordinal>`:

```bash
kubectl -n grafana get pvc | grep production-es-
```

Then query the cluster over HTTPS (security is on by default):

```bash
kubectl -n grafana port-forward svc/production-es-master 9200:9200 &
PW=$(kubectl -n grafana get secret production-es-master-credentials \
  -o jsonpath='{.data.password}' | base64 -d)

# health + node roster. https:// because http.ssl is on, -k because the cert is
# signed by the chart-generated CA
curl -sk -u "elastic:$PW" https://localhost:9200/_cluster/health?pretty
curl -sk -u "elastic:$PW" "https://localhost:9200/_cat/nodes?v"

# the syslog mirror is writing documents
curl -sk -u "elastic:$PW" "https://localhost:9200/syslog-*/_count"
```

With the chart CA exported to a file, drop `-k` and pass `--cacert ca.crt`
(`ca.crt` is inside `production-es-master-certs`).

Expected output: `_cluster/health` reports `"status": "green"`, and `_cat/nodes`
lists one row per pod — 3 rows for Option A, 3 master + 4 data rows for Option B,
with the `node.role` letters matching the roles of each group.

---

## Teardown

Uninstall order: data nodes first, then masters. PVCs survive an uninstall and
block a reinstall under the same `clusterName`/`nodeGroup` until they are
deleted.

```bash
helm uninstall es-data   -n grafana   # Option B only
helm uninstall es-master -n grafana
helm uninstall es        -n grafana   # Option A only

kubectl -n grafana get pvc -l app=production-es-master
kubectl -n grafana delete pvc -l app=production-es-master   # destroys all data
```

---

## Troubleshooting

- **Data pods crash-loop with `master_node_not_discovered_exception` or a seed
  hosts failure** — the master group is not up yet, or it was installed after the
  data group. The data group seeds through `production-es-master-headless`:

```bash
kubectl -n grafana get endpoints production-es-master-headless
```

  Expected output: 3 master pod addresses. Fix that before reading data pod logs.

- **Pods stuck `Pending`** — not enough nodes for `antiAffinity: hard`, or the
  PVCs cannot bind. `kubectl -n grafana describe pod <pod>` shows whether it is a
  scheduling or a StorageClass error; `master-values.yaml` and
  `data-values.yaml` rely on the cluster default StorageClass.
- **`Vm.max_map_count` / bootstrap check failure in pod logs** — the privileged
  `configure-sysctl` init container was blocked. Either allow it or set
  `sysctlInitContainer.enabled: false` and raise `vm.max_map_count=262144` on the
  nodes.
- **Out-of-memory kill on the data group** — the `16g` heap is larger than the
  `12Gi` container limit (see the warning under [Topologies](#topologies)).
- **Readiness probe never passes while the pod is clearly running** — the probe
  waits for `wait_for_status=green` on the local node, which is impossible before
  all replicas of the group exist. Scale `replicas` correctly, or relax it with
  `--set clusterHealthCheckParams="wait_for_status=yellow&timeout=50s"`.
- **Syslog mirror fails the TLS handshake** — the cert SANs are exactly
  `production-es-master`, `production-es-master.grafana` and
  `production-es-master.grafana.svc` (chart `gen-certs` alt names, namespace
  `grafana`), so `elasticsearch.host` must be one of them — the `.svc` form, not
  the `.svc.cluster.local` FQDN — and the Fluent Bit release must live in
  `grafana` so the Secret references resolve.
- **`helm install` reports the release already exists** — use
  `helm upgrade -i <release> elastic/elasticsearch --version 8.5.1 -n grafana -f <values>`.
  Never change `clusterName` or `nodeGroup` on an existing release: those two
  values are the object names, so an upgrade strands the old StatefulSet and its
  PVCs.
- **Data-group pods cannot join the cluster and transport logs show SSL errors** —
  with `createCert: true` each node group generates its own CA
  (`production-es-master-certs` vs `production-es-data-certs`) while transport TLS
  verification mode is `certificate`, so the two groups do not trust each other.
  Generate one Secret once and point every group at it: `createCert: false`, the
  Secret via `secretMounts` at `/usr/share/elasticsearch/config/certs`, and the
  `xpack.security.*` settings from the chart's security example.
