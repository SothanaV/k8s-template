# Clickhouse

- add helm repo
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```
- list app versions
```
helm search repo bitnami/clickhouse --versions
```

example
```
    NAME                            CHART VERSION   APP VERSION     DESCRIPTION                                       
bitnami/clickhouse              9.4.4           25.7.5          ClickHouse is an open-source column-oriented OL...
bitnami/clickhouse              9.4.3           25.7.4          ClickHouse is an open-source column-oriented OL...
bitnami/clickhouse              9.4.2           25.7.3          ClickHouse is an open-source column-oriented OL...
bitnami/clickhouse              9.4.1           25.7.2          ClickHouse is an open-source column-oriented OL...
```

- create the password Secret (the chart reads it via `auth.existingSecret`)
```
kubectl create namespace clickhouse --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic clickhouse-secret -n clickhouse \
  --from-literal=admin-password="<CLICKHOUSE_ADMIN_PASSWORD>"
```

- edit `values.yaml`
- install
```
helm install clickhouse bitnami/clickhouse --namespace clickhouse --create-namespace --version 9.4.4 -f values.yaml
```

- uninstall
```
helm uninstall clickhouse -n clickhouse
# delete pv
kubectl delete pvc --all -n clickhouse

```