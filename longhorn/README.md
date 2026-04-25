# Longhorn install via helm

- add helm repo
```
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

- list app versions
```
helm search repo longhorn/longhorn --versions
```

example
```
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
longhorn/longhorn       1.10.0          v1.10.0         Longhorn is a distributed block storage system ...
longhorn/longhorn       1.9.2           v1.9.2          Longhorn is a distributed block storage system ...
longhorn/longhorn       1.9.1           v1.9.1          Longhorn is a distributed block storage system ...
longhorn/longhorn       1.9.0           v1.9.0          Longhorn is a distributed block storage system ...
```

- edit `values.yaml`

- install
```
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --version 1.10.0 \
  -f values.yaml
```

- uninstall
  - set editor to nano
  ```
  export KUBE_EDITOR="nano"
  ```
  - edit the deleting confirmation flag (`false` → `true`), then save and exit
  ```
  kubectl -n longhorn-system edit settings.longhorn.io deleting-confirmation-flag
  ```
  - uninstall
  ```
  helm uninstall longhorn -n longhorn-system
  ```
  - delete namespace (optional)
  ```
  kubectl delete namespace longhorn-system
  ```

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `persistence.defaultClassReplicaCount` | `2` | Number of replicas for default storage class |
| `persistence.defaultDataLocality` | `best-effort` | Data locality policy (`disabled`, `best-effort`, `strict-local`) |
| `ingress.enabled` | `true` | Enable Longhorn UI ingress |
| `ingress.host` | `longhorn.xxx.com` | Hostname for Longhorn UI |
