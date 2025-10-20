# MinIO

- add helm repo
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```
- list app versions
```
helm search repo bitnami/minio --versions
```

example
```
NAME                    CHART VERSION   APP VERSION     DESCRIPTION                                       
bitnami/minio           17.0.21         2025.7.23       MinIO(R) is an object storage server, compatibl...
bitnami/minio           17.0.19         2025.7.23       MinIO(R) is an object storage server, compatibl...
bitnami/minio           17.0.16         2025.7.23       MinIO(R) is an object storage server, compatibl...
bitnami/minio           17.0.15         2025.7.18       MinIO(R) is an object storage server, compatibl...
bitnami/minio           17.0.14         2025.6.13       MinIO(R) is an object storage server, compatibl...
```

- edit `values.yml`
- install
```
helm install minio bitnami/minio --namespace minio --create-namespace --version 17.0.21 -f values.yaml
```

- uninstall
```
helm uninstall minio -n minio
# delete pv
kubectl delete pvc --all -n minio

```