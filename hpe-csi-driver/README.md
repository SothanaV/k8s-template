# HPE CSI Driver

CSI driver for HPE Alletra/Primera/3PAR arrays. Provides the `hpe-rwo`
(RWO) storage class used by most services in this repo.

The Container Storage Orchestrator (CSO) docs call this the `hpe-csi-driver`
chart from the `hpe-storage` repo.

## Files

| File | Purpose |
|------|---------|
| `values.yaml` | Chart overrides (Alletra6000 enabled, image pins, resources) |
| `default-values.yaml` | Full upstream defaults (`helm show values`) |
| `secret.yaml` | `hpe-backend` Secret template — **edit placeholders before apply** |
| `storage-class.yaml` | `hpe-rwo` StorageClass (xfs, expandable, `Delete` reclaim) |

> **Warning**: `secret.yaml` ships with `<PLACEHOLDER>` values. Keep real
> array credentials in a gitignored `secret.local.yaml` copy.

## Installation

### 1. Add the Helm repository

```bash
helm repo add hpe-storage https://hpe-storage.github.io/co-deployments/
helm repo update
```

### 2. Check available versions

```bash
helm search repo hpe-storage/hpe-csi-driver --versions | head -n 10
```

### 3. Create the namespace and backend Secret

Edit `secret.yaml` (`backend`, `username`, `password`), then:

```bash
kubectl create ns hpe-storage
kubectl apply -f secret.yaml
```

### 4. Install the driver

```bash
helm install hpe-csi-driver hpe-storage/hpe-csi-driver \
  -n hpe-storage --version 3.3.0 \
  -f values.yaml
```

### 5. Create the StorageClass

```bash
kubectl apply -f storage-class.yaml
```

## Verify

```bash
kubectl get pods -n hpe-storage          # csp-daemonset + controller ready
kubectl get storageclass
kubectl get csidrivers | grep hpe
```

Check the backend registered with CSP:

```bash
kubectl get hpebackend -n hpe-storage -o wide
```

## Upgrade

```bash
helm upgrade hpe-csi-driver hpe-storage/hpe-csi-driver \
  -n hpe-storage --version <NEW_VERSION> \
  -f values.yaml
```

> **Warning**: Upgrading the CSI driver restarts the `csp.k8scontext` pods and
> briefly blocks volume provisioning. SSD pods keep their mounts; do not
> delete PVCs during the upgrade window.

## Uninstall

```bash
helm uninstall hpe-csi-driver -n hpe-storage
kubectl delete -f storage-class.yaml
kubectl delete ns hpe-storage
```

> **Warning**: `reclaimPolicy: Delete` — deleting volumes releases them on
> the array. Back up before uninstalling.

## References

- [HPE CSI Driver for Kubernetes docs](https://copr-hpe.github.io/docs/)
- [Chart source](https://github.com/hpe-storage/hpe-csi-driver)
