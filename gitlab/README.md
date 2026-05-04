# GitLab install via Helm

- add helm repo
```
helm repo add gitlab https://charts.gitlab.io/
helm repo update
```

- list app versions
```
helm search repo gitlab/gitlab --versions
```

example
```
NAME            CHART VERSION   APP VERSION     DESCRIPTION
gitlab/gitlab   8.11.1          v18.11.1        Web-based DevOps lifecycle tool
gitlab/gitlab   8.10.3          v18.10.3        Web-based DevOps lifecycle tool
gitlab/gitlab   8.9.4           v18.9.4         Web-based DevOps lifecycle tool
```

- create namespace
```
kubectl create namespace gitlab
```

- create secrets (replace with your secure values)
```
kubectl create secret generic gitlab-postgresql-password -n gitlab \
  --from-literal=postgresql-password="YOUR_SECURE_DB_PASSWORD"

kubectl create secret generic gitlab-redis-secret -n gitlab \
  --from-literal=redis-password="YOUR_SECURE_REDIS_PASSWORD"
```

- configure `values.yaml` with your environment settings

- install
```
helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  -f values.yaml
```

- upgrade
```
helm upgrade gitlab gitlab/gitlab \
  --namespace gitlab \
  -f values.yaml
```

- get initial root password
```
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -ojsonpath='{.data.password}' | base64 --decode ; echo
```

- uninstall
```
helm uninstall gitlab -n gitlab
```

- delete namespace (optional)
```
kubectl delete namespace gitlab
```

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `global.edition` | `ce` | GitLab edition (`ce` = Community, `ee` = Enterprise) |
| `global.gitlabVersion` | `18.11.1` | GitLab app version to deploy |
| `global.hosts.domain` | `gitlab.home.dfellow.com` | Base domain for GitLab |
| `global.ingress.provider` | `nginx` | Ingress controller provider |
| `global.ingress.configureCertmanager` | `false` | Auto-configure cert-manager |
| `postgresql.primary.persistence.size` | `10Gi` | PostgreSQL PVC size |
| `postgresql.primary.persistence.storageClass` | `longhorn` | Storage class for PostgreSQL |
| `redis.architecture` | `standalone` | Redis deployment mode |
| `gitlab.gitaly.persistence.size` | `5Gi` | Gitaly (repository) PVC size |
| `gitlab.gitaly.persistence.storageClass` | `longhorn` | Storage class for Gitaly |
| `gitlab.webservice.minReplicas` | `2` | Min webservice replicas |
| `gitlab.webservice.maxReplicas` | `10` | Max webservice replicas |
| `nginx-ingress.enabled` | `false` | Disable bundled nginx (use external) |

## Sensitive Files

The following files are gitignored and contain sensitive configuration:

- `values.yaml` - Main Helm values (domain, storage class, replicas)
- `oauth/values.yaml` - OAuth configuration values
- `oauth/provider.yaml` - OAuth provider credentials (app_id, app_secret)

> **Warning**: Never commit `values.yaml`, `oauth/values.yaml`, or `oauth/provider.yaml` to version control. Copy `.gitignore` and update with your sensitive file paths.