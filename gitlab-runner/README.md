# GitLab Runner Helm Chart Template

A Helm chart template for deploying GitLab Runner in a Kubernetes cluster with Docker-in-Docker support.

## Prerequisites

- Kubernetes cluster
- Helm 3+ installed
- Access to GitLab instance

## Installation

### 1. Add GitLab Helm Repository

```bash
helm repo add gitlab https://charts.gitlab.io
helm repo update
```

### 2. Search for Available Versions

```bash
helm search repo gitlab/gitlab-runner --versions
```

### 3. Configure values.yml

Edit `values.yml` with your GitLab credentials and cluster configuration:

```yaml
# Required: Replace with your GitLab runner registration token
runnerToken: "<RUNNER_TOKEN>"

# Required: Replace with your GitLab instance URL
gitlabUrl: "<GITLAB_URL>"

# RBAC configuration
rbac:
  create: true

# Service Account configuration
serviceAccount:
  create: true
  name: gitlabrunner-service-account

# Node affinity for runner deployment
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node1
                - node2

# GitLab Runner configuration
runners:
  config: |
    [[runners]]
      gitlab_server_ssl_verify = false
      
      [runners.kubernetes]
        namespace = "{{ default .Release.Namespace .Values.runners.jobNamespace }}"
        image = "alpine"
        privileged = true
        poll_timeout = 600
        
        [[runners.kubernetes.volumes.host_path]]
          name = "docker"
          mount_path = "/var/run/docker.sock"
          read_only = true
          host_path = "/var/run/docker.sock"
```

### 4. Install GitLab Runner

```bash
helm install --namespace <NAMESPACE> gitlab-runner -f values.yml gitlab/gitlab-runner
```

## Configuration Options

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `runnerToken` | GitLab runner registration token | `glrt-xxxxxxx` |
| `gitlabUrl` | GitLab instance URL | `https://gitlab.com/` |

### Service Account

For initial installation, set `serviceAccount.create: true`. After the service account is created, you can change it to `false` on subsequent updates.

```yaml
serviceAccount:
  create: true  # Set to false on updates after first installation
  name: gitlabrunner-service-account
```

### Node Affinity

Configure `affinity` to control which nodes the GitLab Runner pod can be scheduled on. This example restricts the runner to specific nodes:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node1
                - node2
```

### Docker Socket Mount

The template mounts the Docker socket (`/var/run/docker.sock`) to enable Docker-in-Docker (dind) functionality for CI/CD jobs.

## Uninstallation

```bash
helm uninstall --namespace <NAMESPACE> gitlab-runner
```

## Default Configuration Reference

See `default-values.yaml` for all available configuration options including:

- Image configuration
- RBAC settings
- Metrics and monitoring
- Security context
- Resource limits
- Tolerations and node selectors
- Cache configuration (S3, GCS, Azure)
- Session server settings