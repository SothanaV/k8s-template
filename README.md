# k8s-template

Helm chart templates and custom values for self-hosted Kubernetes services.

## Services

| Service | Description | Namespace |
|---------|-------------|-----------|
| [Nginx Ingress](nginx-ingress/README.md) | Ingress controller for Kubernetes | `default` |
| [MetalLB](metallb/MetalLB.md) | Bare-metal load balancer | `metallb-system` |
| [Longhorn](longhorn/README.md) | Distributed block storage | `longhorn-system` |
| [HPE CSI Driver](hpe-csi-driver/README.md) | HPE Alletra CSI driver (`hpe-rwo` storage class) | `hpe-storage` |
| [MinIO](minio/README.md) | S3-compatible object storage | `minio` |
| [PostgreSQL](postgresql/bitnami/README.md) | Relational database (Bitnami chart) | *(per app)* |
| [Airflow](airflow/README.md) | Workflow orchestration | `airflow` |
| [ClickHouse](clickhouse/README.md) | Column-oriented analytics database | `clickhouse` |
| [CloudBeaver](cloudbever/README.md) | Web-based database manager | `cloudbever` |
| [Databasus](databasus/README.md) | Database backup manager | `databasus` |
| [GitLab](gitlab/README.md) | Self-hosted DevOps platform | `gitlab` |
| [GitLab Runner](gitlab-runner/README.md) | CI/CD runner for GitLab | `gitlab-runner` |
| [InfluxDB](influx/README.md) | Time-series database (nginx sidecar for subpath) | `influx` |
| [kube-prometheus-stack](prometheus-stack/README.md) | Cluster monitoring and alerting | `monitoring` |
| [n8n](n8n/README.md) | Workflow automation | `n8n` |
| [Open WebUI](open-webui/README.md) | Web UI for LLMs | `open-webui` |
| [Plane](plane/README.md) | Project tracking | `plane` |
| [Qdrant](qdrant/README.md) | Vector similarity search | `qdrant` |
| [S3 Manager](s3-manager/README.md) | Web UI for S3 buckets | `s3-manager` |
| [SonarQube](sonarqube/README.md) | Code quality and security analysis | `sonarqube` |
| [Superset](superset/README.md) | Data exploration and visualization | `superset` |
| [Traefik](traefik/README.md) | Ingress controller (NGINX provider, NodePort) | `traefik-private` |

## Prerequisites

- Kubernetes cluster
- [Helm](https://helm.sh/docs/intro/install/) >= 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured to target your cluster
- A default storage class (Longhorn or `hpe-rwo` via the HPE CSI driver)

## Quick Start

Each service directory contains:
- `README.md` — install, upgrade, and uninstall instructions
- `values.yaml` / `values.yml` — custom Helm values
- `default-values.yaml` — upstream chart defaults for reference (`helm show values <repo/chart> > default-values.yaml`)

Typical flow:

```bash
helm repo add <repo> <url>
helm repo update
helm search repo <repo>/<chart> --versions   # align chart and app versions
helm install <name> <repo>/<chart> -n <namespace> --create-namespace -f values.yaml
```

## Credentials

> **Warning**: Never commit real credentials. Values files use `<PLACEHOLDER>` tokens or reference pre-created Kubernetes Secrets (`existingSecret`, `secretKeyRef`).

Two conventions are used:

1. **Placeholder** — edit the file and replace `<...>` tokens before `kubectl apply` (e.g. `hpe-csi-driver/secret.yaml`).
2. **Existing Secret** — create the Secret in the target namespace first, then install the chart; see each service README for the Secret name and keys (e.g. `minio`, `clickhouse`, `postgresql`).

Keep real values in `*.local.yaml` copies — they match a gitignore pattern and are never committed.

## Conventions

- Chart/app version pairing: the chart's `APP VERSION` must match the container image tag you deploy.
- Ingress: shared `nginx` ingress class; subpath deployments need app-specific base-URL settings — see the `deploy on subpath` sections in `airflow`, `cloudbever`, `sonarqube`, `open-webui` READMEs.
- Uninstall: `helm uninstall` does not remove PVCs; run `kubectl delete pvc --all -n <namespace>` only when the data is disposable.
