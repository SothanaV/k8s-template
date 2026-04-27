# ClickHouse

Column-oriented analytics database for Kubernetes. Two installation methods are available:

| Method | Directory | Description |
|--------|-----------|-------------|
| [Bitnami](bitnami/README.md) | `bitnami/` | Helm chart — simpler setup, managed replicas |
| [Official (Altinity)](offcial/README.md) | `offcial/` | Altinity operator with `ClickHouseInstallation` CRD |

---

## Method 1 — Bitnami Helm Chart

### Add Helm repository

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

### List available versions

```bash
helm search repo bitnami/clickhouse --versions
```

### Install

Edit [`bitnami/values.yaml`](bitnami/values.yaml) then install:

```bash
helm install clickhouse bitnami/clickhouse \
  --namespace clickhouse \
  --create-namespace \
  --version 9.4.4 \
  -f bitnami/values.yaml
```

### Upgrade

```bash
helm upgrade clickhouse bitnami/clickhouse \
  --namespace clickhouse \
  --version 9.4.4 \
  -f bitnami/values.yaml
```

### Uninstall

```bash
helm uninstall clickhouse -n clickhouse
kubectl delete pvc --all -n clickhouse
```

---

## Method 2 — Official Altinity Operator

### Add Helm repository

```bash
helm repo add altinity https://helm.altinity.com
helm repo update
```

### Install the operator

```bash
helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace clickhouse \
  --create-namespace
```

### Install ClickHouse Keeper

```bash
helm install ck-keeper altinity/clickhouse-keeper \
  --set image.repository=clickhouse/clickhouse-keeper \
  --set image.tag=25.8-alpine \
  --set replicaCount=3 \
  --set persistence.storageClass=hpe-rwo \
  --set persistence.size=20Gi
```

### Deploy ClickHouse cluster

Edit [`offcial/clickhouse-cluster.yaml`](offcial/clickhouse-cluster.yaml) then apply:

```bash
kubectl apply -f offcial/clickhouse-cluster.yaml -n clickhouse
```

### Uninstall

```bash
kubectl delete -f offcial/clickhouse-cluster.yaml -n clickhouse
helm uninstall ck-keeper -n clickhouse
helm uninstall clickhouse-operator -n clickhouse
kubectl delete pvc --all -n clickhouse
```
