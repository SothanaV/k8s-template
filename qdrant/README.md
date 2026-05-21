# Qdrant - Kubernetes Helm Deployment

> **⚠️ NOTE:** This repository contains **example configurations only**. Review and customize all values before deploying to your environment.

This repository contains Helm values for deploying [Qdrant](https://qdrant.tech/) (a vector similarity search engine) on Kubernetes.

## Overview

Qdrant is a vector similarity search engine and database. This deployment configures the official Qdrant Helm chart with cluster mode enabled and custom resource/persistence settings.

## Quick Start

### 1. Add the Helm repository

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm
helm repo update
```

### 2. Search for available versions

```bash
helm search repo qdrant/qdrant --versions
```

### 3. Install

```bash
helm upgrade --install qdrant qdrant/qdrant \
  --create-namespace \
  --namespace qdrant \
  -f values.yaml
```

## Configuration

### Custom Values (`values.yaml`)

The `values.yaml` file contains production-specific overrides:

| Setting | Value | Description |
|---------|-------|-------------|
| `replicaCount` | `1` | Number of replicas |
| `image.repository` | `docker.io/qdrant/qdrant` | Container image |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `resources.limits.cpu` | `8000m` | CPU limit |
| `resources.limits.memory` | `4Gi` | Memory limit |
| `resources.requests.cpu` | `500m` | CPU request |
| `resources.requests.memory` | `1Gi` | Memory request |
| `persistence.storageClass` | `hpe-rwo` | Storage class |
| `persistence.accessMode` | `ReadWriteOnce` | PVC access mode |
| `persistence.size` | `10Gi` | PVC size |

### Default Values (`default-values.yaml`)

The `default-values.yaml` file contains the full set of configurable options from the upstream Helm chart, including:

- **Cluster**: Cluster mode, p2p port, consensus settings
- **Service**: HTTP/GRPC/P2P ports, load balancer config
- **Ingress**: Host routing, TLS, annotations
- **Probes**: Liveness, readiness, startup health checks
- **Persistence**: Storage, snapshot volume configuration
- **Security**: Security context, service account, API keys
- **Sidecars**: Additional container definitions
- **Metrics**: Prometheus ServiceMonitor configuration

### Cluster Mode

Cluster mode is enabled by default in `values.yaml` (via the inherited defaults):

```yaml
config:
  cluster:
    enabled: true
    p2p:
      port: 6335
      enable_tls: false
    consensus:
      tick_period_ms: 100
```

### Snapshots

To enable snapshot persistence for backup/restore:

```yaml
snapshotPersistence:
  enabled: true
  storageClass: "hpe-rwo"
  accessModes: ["ReadWriteOnce"]
  size: 10Gi
```

### API Key Authentication

To configure API key authentication:

```yaml
# Auto-generate an API key
apiKey: true

# Or set a specific API key
apiKey: "your-secret-api-key"

# Read-only API key for queries
readOnlyApiKey: true
```

## Uninstall

```bash
helm uninstall qdrant -n qdrant
```

## Upgrading

```bash
helm upgrade --install qdrant qdrant/qdrant \
  --create-namespace \
  --namespace qdrant \
  -f values.yaml
```

## References

- [Qdrant GitHub](https://github.com/qdrant/qdrant)
- [Qdrant Documentation](https://qdrant.tech/documentation/)
- [Helm Chart Repository](https://qdrant.github.io/qdrant-helm)