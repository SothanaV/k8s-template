# Apache Superset

## Helm chart (core install)

```bash
helm repo add superset http://apache.github.io/superset/
helm repo update
helm search repo superset/superset --versions
```

Edit `values.yaml` (empty by default — start from `default-values.yaml`) then install:

```bash
helm upgrade --install superset superset/superset \
  --namespace superset \
  --create-namespace \
  --version <CHART_VERSION> \
  -f values.yaml
```

Uninstall:

```bash
helm uninstall superset -n superset
kubectl delete pvc --all -n superset
```

## Configuration files

### `superset_config.py`

Python config mounted at `/app/pythonpath/superset_config.py`. It reads all
secrets from environment variables — nothing sensitive is stored in the file:

| Variable | Purpose |
|----------|---------|
| `SUPERSET_SECRET_KEY` | Flask secret key |
| `POSTGRES_SUPERSET_USER/PASSWORD/HOST/PORT/DB` | Metadata database (`SQLALCHEMY_DATABASE_URI`) |
| `REDIS_URI` | Cache backend (Redis DB 1) |
| `DSM_OAUTH_DOMAIN` | Public OAuth server URL (authorize URL, fallback token URL) |
| `DSM_OAUTH_INTERNAL_ADDRESS` | Internal OAuth token URL (service-to-service) |
| `DSM_OAUTH_CLIENT_ID` / `DSM_OAUTH_CLIENT_SECRET` | OAuth client credentials |
| `SUPERSET_WEBSERVER_SERVER_HOST` | optional; used behind ingress |

Auth is OAuth (`AUTH_OAUTH`) with a `CustomSsoSecurityManager` that calls
`/api/v1/account/me` on the provider and maps `is_superuser` to the
Admin/Gamma Superset roles.

Package the config as a Secret:

```bash
kubectl -n superset create secret generic superset-config \
  --from-file=superset_config.py
```

### `mcp.yaml`

Deploys the Superset MCP server (`superset mcp run`, port 5008) as a
Deployment + ClusterIP Service. Expects these objects to exist first in the
`superset` namespace:

- Secret `superset-env` — full environment for Superset (incl. `DATABASE_URI`)
- Secret `superset-config` — the config above
- Secret `reg-magnecomp-secret` — image pull credentials
  (`kubectl create secret docker-registry reg-magnecomp-secret ...`)

Apply:

```bash
kubectl apply -f mcp.yaml
```

## Notes

- The chart's `configOverrides` values and `superset_config.py` must stay in sync — pick one source of truth.
- `WTF_CSRF_ENABLED` and `TALISMAN_ENABLED` are disabled for embedded/iframed dashboards; reconsider before exposing publicly.
