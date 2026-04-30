# Plane Helm Chart

This repository contains custom Helm values for deploying [Plane](https://plane.so) — an open-source software development tool — on Kubernetes.

## Prerequisites

- Kubernetes cluster (v1.20+)
- Helm v3+
- Persistent Volume provisioner (e.g., NFS, HPE, or other storage classes)
- Ingress controller (e.g., NGINX or Traefik)

## Quick Start

### 1. Add the Plane Helm repository

```bash
helm repo add plane https://helm.plane.so/
helm repo update
```

### 2. Search for available versions

```bash
helm search repo plane/plane-ce
```

### 3. Install Plane

```bash
helm install plane plane/plane-ce \
  --version 1.5.0 \
  -f values.yaml \
  --create-namespace \
  --namespace plane \
  --timeout 10m \
  --wait \
  --wait-for-jobs
```

## Configuration

### Custom Values (`values.yaml`)

The `values.yaml` file contains the production overrides for the deployment:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `planeVersion` | Plane application version | `v1.3.0` |
| `ingress.enabled` | Enable ingress | `true` |
| `ingress.appHost` | Application hostname | `wn-a-prd-ai-k8s.tlnw.magnecomp.com` |
| `ingress.ingressClass` | Ingress class | `nginx` |
| `ingress.ingress_annotations` | Ingress annotations | `{}` |
| `redis.storageClass` | Redis storage class | `hpe-rwo` |
| `postgres.storageClass` | PostgreSQL storage class | `hpe-rwo` |
| `rabbitmq.storageClass` | RabbitMQ storage class | `hpe-rwo` |
| `minio.storageClass` | MinIO storage class | `hpe-rwo` |
| `minio.volumeSize` | MinIO volume size | `10Gi` |

### Default Values

Refer to `default-values.yaml` for all available configuration options including:

- **Docker Registry**: Custom registry configuration
- **Ingress**: NGINX/Traefik ingress class support
- **SSL/TLS**: Let's Encrypt and custom TLS configurations
- **Redis**: Service configuration, storage, and resources
- **PostgreSQL**: Database configuration
- **RabbitMQ**: Message broker configuration
- **MinIO**: Object storage configuration
- **Components**: web, space, admin, live, api, worker, beatworker (replicas, resources, images, etc.)
- **External Secrets**: Integration with external secret managers
- **Environment Variables**: All Plane environment configurations

## Architecture

Plane consists of the following components:

| Component | Description |
|-----------|-------------|
| **web** | Frontend web application |
| **space** | Space/Project interface |
| **admin** | Admin panel |
| **live** | Real-time live reloading service |
| **api** | Backend API server |
| **worker** | Background job worker |
| **beatworker** | Scheduled task worker |

### Dependencies

| Service | Purpose |
|---------|---------|
| **Redis** | Caching and session storage |
| **PostgreSQL** | Primary database |
| **RabbitMQ** | Message broker |
| **MinIO** | Object storage (S3-compatible) |

## Uninstall

```bash
helm uninstall plane -n plane
```

## Notes

- Ensure the storage class specified in `values.yaml` exists in your cluster
- Update `ingress.appHost` to match your domain
- Adjust resource limits based on your expected workload
- For production deployments, consider using external services for Redis, PostgreSQL, RabbitMQ, and MinIO/S3