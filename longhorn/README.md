# Lognhorn install via helm


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

- (optional) tag node
```bash
# label
kubectl label nodes <NODE_NAME> role=worker

# verify
kubectl get nodes --show-labels
```

- edit `values.yaml`

- install
```
helm install clickhouse longhorn/longhorn --create-namespace --version 1.10.0 -f values.yaml
```