# Superset MCP on Kubernetes

Deploys and authenticates the Apache Superset MCP service (`superset mcp run`)
alongside an existing Superset install in namespace `superset`.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Topology](#topology)
- [Configuration](#configuration)
- [Authentication modes](#authentication-modes)
- [Why JWT is unavailable today](#why-jwt-is-unavailable-today)
- [Deployment](#deployment)
- [Ingress lockdown](#ingress-lockdown)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)

---

## Prerequisites

- Superset 6.x image with `fastmcp` available (the live image installs it at
  container start)
- An existing `superset` namespace with `superset-config` and `superset-env`
  secrets and a `reg-magnecomp-secret` pull secret
- Redis and PostgreSQL reachable from the new pod (shared with the web tier)
- `superset` namespace access plus permission to edit `ingress/superset`

---

## Topology

| Object | Name | Notes |
| ------ | ---- | ----- |
| Deployment | `superset-mcp` | `superset mcp run --host 0.0.0.0 --port 5008` |
| Service | `superset-mcp` | ClusterIP, port `5008`, named target port `mcp` |
| Ingress | `superset-mcp` | `https://<bi-host>/mcp`, source-range restricted |
| Config source | secret `superset-config` | mounted read-only at `/app/pythonpath` |
| Env source | secret `superset-env` | via `envFrom`; DB and Redis coordinates |

The MCP pod shares the web tier's config secret and metadata database. It holds
no state of its own, so restarts are cheap.

In-cluster consumers call the Service directly:

```bash
http://superset-mcp.superset.svc.cluster.local:5008/mcp
```

**Open WebUI uses this in-cluster path, not the Ingress.** Confirmed from the
MCP pod's access log, which shows the caller's own pod IP rather than a Traefik
pod IP. Ingress-level changes therefore do not affect it.

---

## Configuration

> **Warning:** every `MCP_*` key must live in `superset_config.py`. Setting them
> as container environment variables does nothing. `superset/mcp_service/auth.py`
> reads them through `current_app.config.get(...)`, and Flask config is populated
> only from `superset_config.py`. This is the single most common cause of a
> non-working deployment: a `MCP_AUTH_ENABLED: "true"` env var looks correct and
> is completely inert.

| Key | Default | Description |
| --- | ------- | ----------- |
| `MCP_DEV_USERNAME` | none | Static FAB user assumed by every request. No default; tool calls fail without it or a JWT path. |
| `MCP_AUTH_ENABLED` | `False` | Enables the built-in JWT verifier. |
| `MCP_JWKS_URI` | none | JWKS endpoint for `RS256` verification. |
| `MCP_JWT_PUBLIC_KEY` | none | Static PEM public key, alternative to JWKS. |
| `MCP_JWT_SECRET` | none | Shared secret for `HS256`. |
| `MCP_JWT_ALGORITHM` | `RS256` | `RS256` or `HS256`. |
| `MCP_JWT_ISSUER` / `MCP_JWT_AUDIENCE` | none | Issuer and audience claims to require. |
| `MCP_REQUIRED_SCOPES` | `[]` | Scopes a token must carry. |
| `MCP_RBAC_ENABLED` | `True` | Checks each tool's `class_permission_name` against the FAB security manager for the resolved user. |
| `MCP_AUTH_FACTORY` | none | Callable returning a custom auth provider. Takes precedence over `MCP_AUTH_ENABLED`. |
| `SUPERSET_WEBSERVER_ADDRESS` | `http://localhost:9001` | Base URL used to build Explore and chart-preview links. |

The default `SUPERSET_WEBSERVER_ADDRESS` of `http://localhost:9001` is wrong in
this deployment — set it to the web Service:

```python
SUPERSET_WEBSERVER_ADDRESS = "http://superset.superset.svc:8088"
```

Append `mcp-config-append.py` from this folder to the live secret. Edit in place;
see the README for the merge-patch procedure that preserves
`superset_bootstrap.sh` and `superset_init.sh`.

---

## Authentication modes

| Mode | Works today | Trade-off |
| ---- | ----------- | --------- |
| `MCP_DEV_USERNAME = "admin"` | Yes | Unblocks immediately. Every caller is Superset Admin over all databases. Needs network containment. |
| `MCP_DEV_USERNAME = "data_user"` | Yes | Same mechanism, Gamma read-only. Safer default; needs a lock-down too. |
| JWT via `MCP_JWKS_URI` | **No** | Provider publishes no JWKS and issues opaque tokens. See below. |
| `HS256` with `MCP_JWT_SECRET` | Yes, but pointless alone | See the claims gap below — verifying a token still does not resolve a user. |
| `MCP_AUTH_FACTORY` custom provider | Needs code | Real per-user identity against opaque tokens. Requires the Superset image to carry your provider plus `g.user` middleware. |

The live deployment uses `MCP_DEV_USERNAME = "admin"` with an ingress source-range
restriction.

---

## Why JWT is unavailable today

Verified against the `oauth` deployment in namespace `oauth` (Django 5.1,
`django-oauth-toolkit` 3.0.1).

1. **No JWKS endpoint.** `authen/urls.py` registers only two
   `openid-configuration` views. Both `/.well-known/jwks.json` and
   `/o/.well-known/jwks.json` return 404.
2. **No `jwks_uri` in discovery.** `authen/views.py::_openid_configuration`
   builds the document by hand and never emits the key.
3. **No RSA key.** `OAUTH2_PROVIDER` in `backend/settings.py` sets no
   `OIDC_RSA_KEY`, and the container environment has none. The advertised
   `"id_token_signing_alg_values_supported": ["RS256"]` is a hardcoded literal
   whose source comment reads "Specify the algorithm you are using".
4. **Access tokens are opaque.** `django-oauth-toolkit` 3.0.1 mints random opaque
   access tokens, so there is no JWT for a JWKS-based verifier to check.

Confirm with:

```bash
kubectl -n superset exec deploy/superset-mcp -- python -c \
  "import requests,urllib3;urllib3.disable_warnings();\
   print(requests.get('https://<oauth-host>/.well-known/jwks.json',verify=False).status_code)"
```

Expected output: `404`

### The claims gap (matters even after the provider is fixed)

Nothing in this build maps a verified principal to a Superset FAB user.
`auth.py::get_user_from_request()` tries exactly two things:

1. `g.user`, set by "external middleware" that does not ship with Superset
2. `MCP_DEV_USERNAME`

`jwt_verifier.py` touches claims only for logging and scope checks
(`claims.get("client_id") or claims.get("sub")`) — never to look up a `User`.

**Enabling JWT verification alone still fails with `No authenticated user
found`.** Any claim that Superset resolves users automatically from `sub`,
`client_id`, `email`, or `username` claims does not apply to this build.

To get true per-user RBAC you need both halves:

```python
# superset_config.py
from fastmcp.server.auth import AuthProvider, AccessToken

class UserinfoAuthProvider(AuthProvider):
    async def verify_token(self, token: str) -> AccessToken | None:
        # validate the bearer against the provider userinfo endpoint, which
        # works with opaque tokens and needs no provider change, then
        # return AccessToken(token=..., client_id=..., scopes=[...],
        #                    subject=<username>, claims={...}) or None
        ...

MCP_AUTH_FACTORY = lambda app: UserinfoAuthProvider()
```

plus middleware that copies the verified subject onto `flask.g.user`. The
verified fields for `AccessToken` in fastmcp 3.2.4 are `token`, `client_id`,
`scopes`, `expires_at`, `resource`, `subject`, `claims`.

---

## Deployment

### 1. Confirm the target FAB user exists

```bash
kubectl -n superset exec deploy/superset-mcp -- python -c \
  "import superset.app as a;app=a.create_app()
with app.app_context():
    from superset.mcp_service.auth import load_user_with_relationships as L
    u=L('<username>'); print(u.username,[r.name for r in u.roles])"
```

Expected output: `admin ['Admin']`

**An assumed username that does not resolve is a hard failure at call time, not
at startup.**

### 2. Add the MCP keys to the live config secret

Append `mcp-config-append.py` to the decoded `superset_config.py` and merge-patch
it back. Verify the payload:

```bash
kubectl -n superset get secret superset-config \
  -o jsonpath='{.data.superset_config\.py}' | base64 -d | grep -n 'MCP_'
```

### 3. Deploy the workload

```bash
kubectl apply -f mcp/mcp.yaml
kubectl rollout status deploy/superset-mcp -n superset --timeout=420s
```

The container installs `fastmcp` at start, so allow several minutes.

### 4. Strip inert and plaintext env vars

```bash
kubectl -n superset set env deploy/superset-mcp -c mcp-service \
  SUPERSET_USERNAME- SUPERSET_PASSWORD- SUPERSET_BASE_URL- MCP_AUTH_ENABLED-
kubectl -n superset get deploy superset-mcp \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
```

Expected output: `FLASK_APP` and `PYTHONPATH` only.

> **Warning:** omitting these from `mcp/mcp.yaml` does **not** remove them. Objects
> added via the dashboard are missing from `last-applied-configuration`, so the
> apply merge keeps them. Rotate any credential that was published in a
> Deployment spec.

### 5. Apply the ingress lockdown

```bash
kubectl apply -f mcp/mcp-ingress.yaml
kubectl patch ingress superset -n superset --type=json \
  -p '[{"op":"remove","path":"/spec/rules/0/http/paths/1"}]'
```

**The `/mcp` path must be removed from the shared `superset` Ingress**, otherwise
two routes match `/mcp` and routing is non-deterministic.

### 6. Probes must be `tcpSocket`

This build registers no HTTP health route. A `httpGet /health` probe fails
permanently and CrashLoops the pod. `PRODUCTION.md` inside the image documents
`GET /health`, but no such route exists.

---

## Ingress lockdown

Traefik here runs `--providers.kubernetesingressnginx` (nginx-migration,
`controllerClass=k8s.io/ingress-nginx`). Consequences:

- `nginx.ingress.kubernetes.io/*` annotations **work**
- `traefik.ingress.kubernetes.io/*` annotations and `traefik.io/v1alpha1`
  `Middleware` references are **silently ignored**

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8"
```

Prove enforcement rather than trusting the apply, by temporarily inverting the
range:

```bash
kubectl -n superset annotate ingress superset-mcp --overwrite \
  'nginx.ingress.kubernetes.io/whitelist-source-range=203.0.113.0/24'
```

Expected output: `403` from `/mcp`. **If it still returns 200, your restriction
is not wired up** — this is exactly how a Traefik `ipAllowList` middleware
presented as a working lockdown.

> **Warning:** Calico preserves pod source IPs for in-cluster traffic, so an
> in-cluster caller appears as `10.42.x` and is rejected by a node-only range
> such as `10.16.0.0/16`. `10.0.0.0/8` admits internal clients while blocking the
> public internet.

---

## Verification

Health and instance data are the real proof that user resolution works:

```bash
kubectl -n superset run tmp-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- sh -c \
  'curl -s -X POST http://superset-mcp:5008/mcp \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"health_check\",\"arguments\":{}}}"'
```

Expected output:

```
data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"status\":\"healthy\", ... \"service\":\"Superset MCP Service\""}],"isError":false}}
```

`tools/list` returning 200 proves only that the transport works — it is
unauthenticated and does not resolve a user. A tool that reads data is the actual
test; `get_instance_info` needs `{"request":{}}`.

Effective config inside the pod:

```bash
kubectl -n superset exec deploy/superset-mcp -- python -c \
  "import superset.app as a;c=a.create_app().config;\
   print(c.get('MCP_DEV_USERNAME'), c.get('MCP_RBAC_ENABLED'))"
```

Expected output: `admin True`

Regression-check the web UI after ingress edits — it should redirect, not error:

```
GET https://<bi-host>/    -> 302
```

---

## Troubleshooting

**`No authenticated user found. Tried: g.user was not set by JWT middleware (MCP_AUTH_ENABLED=False, JWT keys configured=False); MCP_DEV_USERNAME is not configured`**
`MCP_*` was set as an environment variable. Move it to `superset_config.py` and
restart. This is the failure mode the original manifest in this folder shipped
with.

**`User '<name>' not found. Please create admin user with: superset fab create-admin`**
`MCP_DEV_USERNAME` names a user that does not exist in the FAB user table.

**`Validation error in <tool>: request: Missing required argument`**
Not an auth failure — authentication succeeded. Wrap the arguments as
`{"request": {...}}`.

**`CreateContainerConfigError`**
The manifest references a `superset-env` key that does not exist, historically
`DATABASE_URI`. The SQLAlchemy URI comes from `superset_config.py`.

**Pod Ready but probes fail / CrashLoopBackOff**
`httpGet` probes on `/health`. Only `/mcp` is routed; `/`, `/health`, `/healthz`
and `/metrics` all return 404.

**`Failed to log error event: DBEventLogger.log() missing 3 required positional arguments: 'dashboard_id', 'slice_id', and 'referrer'`**
Upstream bug. Tool activity is never persisted to the DB event log — stdout is
the only audit trail.

**Session errors or dropped long-running queries through the ingress**
Add the nginx timeout annotations (`proxy-read-timeout`, `proxy-send-timeout`,
`proxy-buffering: "off"`). Traefik-style equivalents will not apply.

**`/mcp` returns 403**
Source outside `whitelist-source-range`. Remember pod IPs are preserved.

---

## Known limitations

- Every MCP caller shares one identity. With `admin`, any workload that can reach
  `superset-mcp.superset.svc:5008` has `execute_sql` over every database,
  bypassing the ingress restriction entirely.
- No audit trail: the `DBEventLogger` bug means MCP activity is not recorded in
  the metadata database.
- `pip install fastmcp` runs at every container start — unpinned (resolving
  3.2.4) and dependent on PyPI egress. Bake it into the image.
- Replicas stay at 1. Streamable-HTTP sessions are in-process, so scaling out
  without a shared event store makes long sessions bounce between pods.
- Helm does not manage this namespace: the `superset` release reports `failed`
  while the Deployment carries dozens of dashboard hand-edits.
