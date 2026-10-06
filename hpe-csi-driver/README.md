# HPE CSI Driver

CSI driver for HPE Alletra/Primera/3PAR arrays. Provides the `hpe-rwo`
(RWO) and `hpe-rwx` (RWX, via NFS) storage classes used by services in
this repo.

The Container Storage Orchestrator (CSO) docs call this the `hpe-csi-driver`
chart from the `hpe-storage` repo.

## Files

| File | Purpose |
|------|---------|
| `values.yaml` | Chart overrides (Alletra6000 enabled, image pins, resources) |
| `default-values.yaml` | Full upstream defaults (`helm show values`) |
| `secret.yaml` | `hpe-backend` Secret template — **edit placeholders before apply** |
| `storage-class.yaml` | `hpe-rwo` + `hpe-rwx` StorageClasses (ext4, iSCSI, expandable, `Delete` reclaim) |
| `test-deploy.yaml` | Smoke test: PVC (`hpe-rwx`) + nginx Deployment writing to `/data` |
| `report.md` / `report.pdf` | Incident report: provisioning failure caused by cluster DNS loss (placeholders for infra names/IPs) |

> **Warning**: `secret.yaml` ships with `<PLACEHOLDER>` values. Keep real
> array credentials in a gitignored `secret.local.yaml` copy.

## Storage classes

Both classes use provisioner `csi.hpe.com`, `accessProtocol: iscsi`,
`fstype: ext4`, `allowVolumeExpansion: true`, `reclaimPolicy: Delete`, and
reference the `hpe-backend` Secret (namespace `hpe-storage`) for all four
secret hooks (provision / node-stage / node-publish / expand).

| Class | Access | Notes |
|-------|--------|-------|
| `hpe-rwo` | ReadWriteOnce | Block (iSCSI/multipath). Pin Deployment to `strategy: Recreate` |
| `hpe-rwx` | ReadWriteMany | `nfsResources: "true"` — CSI creates backing NFS exports |

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

### 5. Create the StorageClasses (rwo + rwx)

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

Smoke test (nginx pod writing to `/data`):

```bash
kubectl apply -f test-deploy.yaml
kubectl get pvc,po -l app=my-app -w
kubectl delete -f test-deploy.yaml
```

## Known issue: DNS dependency in the storage path

The CSP login uses `http://<serviceName>:8080` from the `hpe-backend`
Secret, and the CSP resolves the array FQDN itself — so provisioning
depends fully on cluster DNS (no fallback). See `report.md` for an incident
where broken cross-node DNS left pods stuck in `Pending`.

On affected clusters the Secret was patched to IP literals as a workaround:

```bash
kubectl patch secret hpe-backend -n hpe-storage --type merge \
  -p '{"data":{"serviceName":"'"$(printf '<CSP_SVC_CLUSTER_IP>' | base64)"'"}}'
kubectl patch secret hpe-backend -n hpe-storage --type merge \
  -p '{"data":{"backend":"'"$(printf '<ARRAY_MGMT_IP>' | base64)"'"}}'
kubectl rollout restart deploy/hpe-csi-controller -n hpe-storage
```

> **Warning**: this patch lives outside Helm. A `helm upgrade/rollback` of
> the CSI release reverts the Secret to `values`/manifest content and
> re-breaks provisioning until patched again.

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
