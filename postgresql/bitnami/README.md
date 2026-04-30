# PostgreSQL Helm Chart

This directory contains a Helm chart configuration for deploying PostgreSQL using the Bitnami chart, configured for SonarQube.

## Prerequisites

- Kubernetes 1.19+
- Helm 3+
- PV provisioner support in the underlying cluster

## Chart Source

This chart uses the Bitnami PostgreSQL chart as its source:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

## Installation

### Search available versions

```bash
helm search repo bitnami/postgresql --versions
```

### Install with custom values

```bash
helm install postgresql bitnami/postgresql --version 18.5.1 --namespace sonarqube -f values.yaml
```

## Configuration

### Current Values (`values.yaml`)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `global.postgresql.auth.username` | `sonarqube` | Custom PostgreSQL username |
| `global.postgresql.auth.database` | `sonarqube` | Custom database name |
| `image.registry` | `registry-1.docker.io` | Docker image registry |
| `image.repository` | `bitnamilegacy/postgresql` | PostgreSQL image repository |
| `image.tag` | `17.6.0` | PostgreSQL image tag |
| `persistence.storageClass` | `hpe-rwx` | PVC storage class |
| `persistence.accessMode` | `ReadWriteOnce` | PVC access mode |
| `persistence.size` | `8Gi` | PVC storage size |
| `primary.resources.limits.cpu` | `500m` | CPU limit |
| `primary.resources.limits.memory` | `512Mi` | Memory limit |
| `primary.resources.requests.cpu` | `250m` | CPU request |
| `primary.resources.requests.memory` | `256Mi` | Memory request |

### Environment Variables

The following environment variables will be available for connecting to PostgreSQL:

| Variable | Value |
|----------|-------|
| `POSTGRES_USERNAME` | `sonarqube` |
| `POSTGRES_DATABASE` | `sonarqube` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_HOST` | `postgresql` |

### Persistence

Data is persisted using a PVC with the following configuration:

- **Storage Class:** `hpe-rwx`
- **Access Mode:** `ReadWriteOnce`
- **Size:** `8Gi`
- **Mount Path:** `/bitnami/postgresql`

### Resources

CPU and memory resources are configured as follows:

- **Requests:** 250m CPU, 256Mi memory
- **Limits:** 500m CPU, 512Mi memory

## Uninstall

```bash
helm uninstall postgresql --namespace sonarqube
```

## Upgrading

```bash
helm upgrade postgresql bitnami/postgresql --version 18.5.1 --namespace sonarqube -f values.yaml