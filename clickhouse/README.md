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

- edit `values.yml`
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