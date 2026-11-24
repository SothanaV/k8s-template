# PostgreSQL

PostgreSQL for Kubernetes. Three installation methods are available:

| Method | Directory | Description |
| ------ | --------- | ----------- |
| [Custom](custom/README.md) | `custom/` | Self-contained chart in this repo — `postgres:18-alpine`, no upstream chart dependency |
| [HA cluster](sothanav-ha-pg/README.md) | `sothanav-ha-pg/` | Self-contained chart — 3 repmgr nodes with automatic failover + pgcat read/write pooler |
| [Bitnami](bitnami/README.md) | `bitnami/` | Upstream `bitnami/postgresql` chart with values overrides |

---

## Which one to use

| Need | Use |
| ---- | --- |
| PostgreSQL 18, templates you can read and edit in-repo | `custom/` |
| Survives a node or pod loss, with one endpoint that follows the primary | `sothanav-ha-pg/` |
| Read/write splitting and connection pooling in front of the database | `sothanav-ha-pg/` |
| Replication or metrics exporter from an upstream chart, TLS, or other chart features | `bitnami/` |
| No internet access to the Bitnami chart repo | `custom/` or `sothanav-ha-pg/` |
| An already-running release installed from the Bitnami chart | `bitnami/` — the three are not interchangeable in place |

`custom/` is single-instance by design (StatefulSet, one replica, RWO PVC). A second
postgres process on the same data directory corrupts it, so read replicas are out of scope
there: use `sothanav-ha-pg/` (its own chart, its own image, one volume per node) or
`bitnami/`.

---

## Custom chart (18-alpine)

```bash
kubectl -n <namespace> create secret generic postgresql-secret \
  --from-literal=postgres-password="<POSTGRES_SUPERUSER_PASSWORD>"

helm install postgresql postgresql/custom \
  -n <namespace> \
  --set persistence.storageClass=<STORAGE_CLASS>
```

Full details, including the PG 18 data-directory change and init-script behaviour, are in
[`custom/README.md`](custom/README.md).

---

## HA cluster (repmgr + pgcat)

Pulls `sothanav/pg-ha:18-repmgr` (this directory's `sothanav-ha-pg/image/` — repmgr is an apt
package, so there is no official image to pull) and needs a Secret with three passwords:

```bash
kubectl -n <namespace> create secret generic pg-ha-secret \
  --from-literal=postgres-password="<POSTGRES_SUPERUSER_PASSWORD>" \
  --from-literal=repmgr-password="<REPMGR_REPLICATION_PASSWORD>" \
  --from-literal=pgcat-admin-password="<PGCAT_LOCAL_ADMIN_PASSWORD>"

helm install pg-ha postgresql/sothanav-ha-pg \
  -n <namespace> \
  --set persistence.storageClass=<STORAGE_CLASS>
```

Air-gapped nodes, or you would rather build the image yourself:

```bash
docker build -t <REGISTRY>/pg-ha:18-repmgr postgresql/sothanav-ha-pg/image
docker push  <REGISTRY>/pg-ha:18-repmgr
# then add --set image.repository=<REGISTRY>/pg-ha
```

Applications then use `pgcat.<namespace>.svc:6432`: writes go to whichever node repmgr
promoted, reads spread over the standbys, and a failover is absorbed inside the pooler
instead of changing a connection string. ReadWriteOnce storage is enough — the role
propagation goes through a ConfigMap and the Kubernetes API, not a shared volume.

Failover drill, RBAC, password rotation, and the differences from the
`docker-template/postgresql/postgresql-ha` compose stack are in
[`sothanav-ha-pg/README.md`](sothanav-ha-pg/README.md).

---

## Bitnami chart

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/postgresql --versions

helm install postgresql bitnami/postgresql --version 18.5.1 \
  -n <namespace> -f postgresql/bitnami/values.yaml
```

See [`bitnami/README.md`](bitnami/README.md) for the Secret keys it expects and the
`bitnamilegacy/postgresql` image pinning.

---

## Version note

`custom/` tracks the Docker Hub official image tag (`18-alpine`) with no chart-version
constraint. The Bitnami chart and its image tag must be kept in step manually — this repo
pins chart `18.5.1` with `bitnamilegacy/postgresql:17.6.0`, which is why `custom/` exists.
`sothanav-ha-pg/` has no upstream to track: you build its image from
`sothanav-ha-pg/image/Dockerfile`, so its PostgreSQL version is whatever that Dockerfile
pins, and `appVersion` plus `repmgr.pgBindir` record the major it expects.

## Uninstall

```bash
helm uninstall postgresql -n <namespace>
```

Neither method deletes data by default. Remove the volume only when it is disposable:

```bash
kubectl delete pvc --all -n <namespace>
```

For the HA chart the claims are `pgdata-pg-ha-0` .. `pgdata-pg-ha-<n>`, and the default
`persistence.reclaimPolicy: Retain` plus `whenScaled: Retain` keeps them through both
`helm uninstall` and a scale-down.
