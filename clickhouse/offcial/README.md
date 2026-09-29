# ClickHouse — Official Altinity Operator

ClickHouse via the Altinity `ClickHouseInstallation` CRD. See
[../README.md](../README.md) for both installation methods.

## Files

| File | Purpose |
|------|---------|
| `clickhouse-cluster.yaml` | `ClickHouseInstallation` manifest (1 shard x 3 replicas) |

## Installation

### 1. Add the Helm repository

```bash
helm repo add altinity https://helm.altinity.com
helm repo update
```

### 2. Install the operator

```bash
helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace clickhouse --create-namespace
```

### 3. Install ClickHouse Keeper

```bash
helm install ck-keeper altinity/clickhouse-keeper \
  --set image.repository=clickhouse/clickhouse-keeper \
  --set image.tag=25.8-alpine \
  --set replicaCount=3 \
  --set persistence.storageClass=hpe-rwo \
  --set persistence.size=20Gi
```

Pin Keeper pods to specific nodes with node affinity (replace the host list):

```bash
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=kubernetes.io/hostname" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values={node04,node05,node06,node07}"
```

### 4. Deploy the cluster

Edit `clickhouse-cluster.yaml` first:

- `admin/password` — replace `<CLICKHOUSE_ADMIN_PASSWORD>`, or better, switch
  to a Secret-based user config for production
- `zookeeper.nodes` — must match the Keeper StatefulSet/service names
- affinity hostnames and `storageClassName` — match your cluster

```bash
kubectl apply -f clickhouse-cluster.yaml -n clickhouse
```

## Verify

```bash
kubectl get clickhouseinstallations -n clickhouse
kubectl get pods -n clickhouse -l clickhouse.altinity.com/app=ch0
kubectl exec -n clickhouse chi-tlnw-prd-cluster-prd-cluster-0-0-0 -- \
  clickhouse-client --password '<CLICKHOUSE_ADMIN_PASSWORD>' -q 'SELECT 1'
```

## Uninstall

```bash
kubectl delete -f clickhouse-cluster.yaml -n clickhouse
helm uninstall ck-keeper -n clickhouse
helm uninstall clickhouse-operator -n clickhouse
kubectl delete pvc --all -n clickhouse
```

## References

- [Altinity operator docs](https://docs.altinity.com/altinity_operator/)
- [ClickHouse docs](https://clickhouse.com/docs)
