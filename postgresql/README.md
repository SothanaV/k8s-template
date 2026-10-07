# PostgreSQL

PostgreSQL for Kubernetes. Two installation methods are available:

| Method | Directory | Description |
| ------ | --------- | ----------- |
| [Custom](custom/README.md) | `custom/` | Self-contained chart in this repo — `postgres:18-alpine`, no upstream chart dependency |
| [Bitnami](bitnami/README.md) | `bitnami/` | Upstream `bitnami/postgresql` chart with values overrides |

---

## Which one to use

| Need | Use |
| ---- | --- |
| PostgreSQL 18, templates you can read and edit in-repo | `custom/` |
| Replication / HA, metrics exporter, TLS, or other chart features | `bitnami/` |
| No internet access to the Bitnami chart repo | `custom/` |
| An already-running release installed from the Bitnami chart | `bitnami/` — the two are not interchangeable in place |

`custom/` is single-instance by design (StatefulSet, one replica, RWO PVC). A second
postgres process on the same data directory corrupts it, so read replicas are out of scope
there; use `bitnami/` if you need replication.

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

## Uninstall

```bash
helm uninstall postgresql -n <namespace>
```

Neither method deletes data by default. Remove the volume only when it is disposable:

```bash
kubectl delete pvc --all -n <namespace>
```
