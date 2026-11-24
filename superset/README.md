# Apache Superset

Kubernetes deployment assets for the production Superset BI stack in namespace
`superset`, including the MCP (Model Context Protocol) server.

## Table of Contents

- [Layout](#layout)
- [Prerequisites](#prerequisites)
- [Helm chart (core install)](#helm-chart-core-install)
- [Configuration files](#configuration-files)
- [MCP server](#mcp-server)
- [Applying changes to the live namespace](#applying-changes-to-the-live-namespace)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## Layout

```
superset/
├── README.md                  # this file
├── default-values.yaml        # upstream chart defaults, for reference
├── values.yaml                # empty by default; copy from default-values.yaml
├── superset_config.py         # sanitized config TEMPLATE (see warning below)
└── mcp/                       # MCP server deployment assets
    ├── how-to-superset-mcp.md # MCP deployment + authentication deep dive
    ├── mcp.yaml               # MCP Deployment + ClusterIP Service
    ├── mcp-ingress.yaml       # MCP Ingress with source-range restriction
    └── mcp-config-append.py   # MCP_* keys to append to the live config secret
```

### File Reference

| File | Description |
| ---- | ----------- |
| `superset/default-values.yaml` | Chart defaults (32 KB). Start here when creating a `values.yaml`. |
| `superset/values.yaml` | Currently empty. `helm upgrade -f` against it installs stock defaults. |
| `superset/superset_config.py` | Env-var-driven config template. **Not** what runs in prod. |
| `superset/mcp/mcp.yaml` | `deploy/superset-mcp` + `svc/superset-mcp`, kept reconciled with the live objects. |
| `superset/mcp/mcp-ingress.yaml` | `ingress/superset-mcp`, isolates `/mcp` so its allowlist never gates the web UI. |
| `superset/mcp/mcp-config-append.py` | Fragment appended to the live `superset-config` secret. Not standalone. |
| `superset/mcp/how-to-superset-mcp.md` | MCP auth modes, the JWKS blockers, and verified failure modes. |

---

## Prerequisites

- Kubernetes cluster (this one: RKE2 v1.31.14, Calico CNI)
- Helm 3+
- `kubectl` access to the `superset` namespace
- A registry pull secret named `reg-magnecomp-secret` in the namespace
- Traefik with the **`kubernetesingressnginx`** provider (see
  [Ingress annotations](#ingress-annotations))

---

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

> **Warning:** `kubectl delete pvc --all -n superset` destroys the metadata
> PostgreSQL and its Redis. There is no undo.

> **Warning:** on the live cluster the Helm release `superset` reports status
> `failed` at revision 1, while the Deployment carries 57 generations of
> dashboard hand-edits. Helm is **not** the source of truth here — do not run
> `helm upgrade` or `helm rollback` expecting it to converge the namespace.

---

## Configuration files

### `superset_config.py`

Python config mounted at `/app/pythonpath/superset_config.py`. Superset loads it
into Flask config at process start; `PYTHONPATH=/app/pythonpath` is what makes it
importable. On startup the log line
`Loaded your LOCAL configuration at [/app/pythonpath/superset_config.py]`
confirms it was picked up.

> **Warning:** the copy in this folder is a **sanitized template** and is
> structurally different from the live secret. The repo version reads
> `SUPERSET_SECRET_KEY` and `POSTGRES_SUPERSET_*`; the live secret reads
> `DB_USER`/`DB_PASS`/`DB_HOST`/`DB_PORT`/`DB_NAME`, `REDIS_PROTO`/`REDIS_HOST`/
> `REDIS_PORT`/`REDIS_DB`/`REDIS_CELERY_DB`, and additionally defines the Celery
> beat schedule, SMTP, `FEATURE_FLAGS`, `RESULTS_BACKEND`, and a duckdb `httpfs`
> install at import time. Running
> `kubectl create secret generic superset-config --from-file=superset_config.py`
> **overwrites all of that and breaks OAuth login, alert reports, and thumbnails.**

Variables read by this template:

| Variable | Purpose |
| -------- | ------- |
| `SUPERSET_SECRET_KEY` | Flask secret key |
| `POSTGRES_SUPERSET_USER/PASSWORD/HOST/PORT/DB` | Metadata database (`SQLALCHEMY_DATABASE_URI`) |
| `REDIS_URI` | Cache backend (Redis DB 1) |
| `DSM_OAUTH_DOMAIN` | Public OAuth server URL (authorize URL, fallback token URL) |
| `DSM_OAUTH_INTERNAL_ADDRESS` | Internal OAuth token URL (service-to-service) |
| `DSM_OAUTH_CLIENT_ID` / `DSM_OAUTH_CLIENT_SECRET` | OAuth client credentials |

**`SUPERSET_WEBSERVER_ADDRESS` is not derived from an environment variable in
this template** and defaults to `http://localhost:9001`, which breaks Explore and
chart-preview links. Set it explicitly — see
[how-to-superset-mcp.md](mcp/how-to-superset-mcp.md).

Auth is OAuth (`AUTH_OAUTH`) with a `CustomSsoSecurityManager` that calls
`/api/v1/account/me` on the provider and maps `is_superuser` to the
Admin/Gamma Superset roles.

### `superset-env` (Secret)

Consumed via `envFrom` by both `deploy/superset` and `deploy/superset-mcp`.
Keys present on the live cluster:

```
DB_HOST DB_NAME DB_PASS DB_PORT DB_USER
REDIS_CELERY_DB REDIS_DB REDIS_HOST REDIS_PORT REDIS_PROTO REDIS_USER
```

**There is no `DATABASE_URI` key.** Referencing one from a manifest produces
`CreateContainerConfigError`. The SQLAlchemy URI is assembled in
`superset_config.py`, not from an env var.

### Packaging the live config

Edit in place rather than recreating, so the other two keys
(`superset_bootstrap.sh`, `superset_init.sh`) survive:

```bash
kubectl -n superset get secret superset-config \
  -o jsonpath='{.data.superset_config\.py}' | base64 -d > /tmp/sc.py
# ...edit /tmp/sc.py...
NEW=$(base64 -w0 /tmp/sc.py)
kubectl -n superset patch secret superset-config --type merge \
  -p "{\"data\":{\"superset_config.py\":\"$NEW\"}}"
kubectl -n superset rollout restart deploy/superset-mcp
```

**Only `deploy/superset-mcp` needs the restart; the web pod reloads at its next
natural restart.**

---

## MCP server

`deploy/superset-mcp` runs `superset mcp run --host 0.0.0.0 --port 5008`
(Streamable-HTTP at `/mcp`) and shares the web pods' config secret and metadata
database.

Full details — authentication modes, why JWT is unavailable, the probe trap —
are in [`how-to-superset-mcp.md`](mcp/how-to-superset-mcp.md).

Apply:

```bash
kubectl apply -f mcp/mcp.yaml
kubectl apply -f mcp/mcp-ingress.yaml
```

### Ingress annotations

Traefik here runs the **nginx-migration provider**, not `kubernetesingress`:

```
--providers.kubernetesingressnginx
--providers.kubernetesingressnginx.controllerClass=k8s.io/ingress-nginx
--providers.kubernetesingressnginx.ingressClass=traefik
```

**Only `nginx.ingress.kubernetes.io/*` annotations are honoured. `traefik.ingress.kubernetes.io/*` annotations and `traefik.io/v1alpha1 Middleware` references are silently ignored** — an `ipAllowList` middleware so configured returned HTTP 200 even when its allowlist was inverted to `203.0.113.0/24`. Use
`nginx.ingress.kubernetes.io/whitelist-source-range` instead.

---

## Applying changes to the live namespace

The namespace is hand-edited, so `kubectl apply` alone under-applies.

> **Warning:** environment variables added through the dashboard are absent from
> `kubectl.kubernetes.io/last-applied-configuration`, so the apply-time merge
> **leaves them in place** even after you delete them from the manifest. This is
> how plaintext admin credentials survived a manifest cleanup. Verify with
> `kubectl diff -f mcp/mcp.yaml`, then strip explicitly:

```bash
kubectl -n superset set env deploy/superset-mcp -c mcp-service \
  SUPERSET_USERNAME- SUPERSET_PASSWORD- SUPERSET_BASE_URL- MCP_AUTH_ENABLED-
```

Roll back from a backup:

```bash
kubectl -n superset apply -f /tmp/superset-mcp-backup/deploy-superset-mcp.yaml
```

---

## Security notes

- `MCP_DEV_USERNAME` grants every MCP caller one shared identity. The live value
  is `admin`, so anyone who can reach port 5008 has `execute_sql` over every
  database. `ingress/superset-mcp` restricts the ingress path, but **in-cluster
  callers reach `superset-mcp.superset.svc:5008` directly and bypass it.**
- The live config keeps `SECRET_KEY` and the OAuth `client_secret` inline, and
  sets `verify=False` on provider calls. The repo template shows the target
  state (secret refs) — migrating the live secret is outstanding.
- `WTF_CSRF_ENABLED` and `TALISMAN_ENABLED` are disabled for embedded/iframed
  dashboards; reconsider before exposing publicly.
- The admin password that was published in the Deployment spec still needs
  rotating.

---

## Troubleshooting

**`superset-mcp` pod stuck in `CreateContainerConfigError`**
A manifest references a `superset-env` key that does not exist (historically
`DATABASE_URI`). Check `kubectl describe pod -n superset <pod>` for the missing
key name.

**Pod never becomes Ready / CrashLoops after re-applying `mcp/mcp.yaml`**
The probes were set to `httpGet /health`. This build registers no HTTP health
route (`/`, `/health`, `/healthz`, `/metrics` all return 404; only `/mcp`
exists). Keep the `tcpSocket` probes.

**Every MCP tool call returns `No authenticated user found`**
`MCP_*` was set as a container env var. Those keys are read from Flask config,
which only comes from `superset_config.py`. See
[how-to-superset-mcp.md](mcp/how-to-superset-mcp.md).

**`/mcp` returns 403**
`nginx.ingress.kubernetes.io/whitelist-source-range` rejected the source. Calico
preserves pod source IPs, so an in-cluster caller appears as `10.42.x`, not as a
node IP.

**`Failed to log error event: DBEventLogger.log() missing 3 required positional arguments`**
Upstream bug in this build. MCP tool activity is never written to the DB event
log; stdout is the only audit trail.

**Superset login or alert reports break after a config change**
The live secret was replaced with the repo template. Restore from backup and
merge instead of overwriting.

---

## Notes

- The chart's `configOverrides` values and `superset_config.py` must stay in
  sync — pick one source of truth.
