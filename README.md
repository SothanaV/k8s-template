# k8s-template

Helm chart templates and custom values for self-hosted Kubernetes services.

## Services

| Service | Description | Namespace |
|---------|-------------|-----------|
| [Nginx Ingress](nginx-ingress/README.md) | Ingress controller for Kubernetes | `nginx-ingress` |
| [Longhorn](longhorn/README.md) | Distributed block storage | `longhorn-system` |
| [MinIO](minio/README.md) | S3-compatible object storage | `minio` |
| [Airflow](airflow/README.md) | Workflow orchestration | `airflow` |
| [ClickHouse](clickhouse/README.md) | Column-oriented analytics database | `clickhouse` |
| [CloudBeaver](cloudbever/README.md) | Web-based database manager | `cloudbever` |
| [Databasus](databasus/README.md) | Database management UI | `databasus` |
| [GitLab](gitlab/README.md) | Self-hosted DevOps platform | `gitlab` |
| [GitLab Runner](gitlab-runner/README.md) | CI/CD runner for GitLab | `gitlab-runner` |
| [n8n](n8n/README.md) | Workflow automation | `n8n` |
| [S3 Manager](s3-manager/README.md) | Web UI for S3 buckets | `s3-manager` |
| [SonarQube](sonarqube/README.md) | Code quality and security analysis | `sonarqube` |

## Prerequisites

- Kubernetes cluster
- [Helm](https://helm.sh/docs/intro/install/) >= 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured to target your cluster
- Longhorn installed as the default storage class (required by most services)

## Quick Start

Each service directory contains:
- `README.md` — install, upgrade, and uninstall instructions
- `values.yaml` / `values.yml` — custom Helm values
