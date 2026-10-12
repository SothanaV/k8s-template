# Grafana MCP (`mcp-grafana`)

Deploys [grafana/mcp-grafana](https://github.com/grafana/mcp-grafana) — a Model
Context Protocol server that exposes Grafana dashboards, datasources, alerts,
incidents and log/metric queries as MCP tools — as a **streamable HTTP** server
behind the shared `nginx` ingress.

## Table of Contents

- [Files](#files)
- [Choose an Installation Method](#choose-an-installation-method)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Values Reference](#values-reference)
- [Calling the Server](#calling-the-server)
- [Verify](#verify)
- [Upgrading](#upgrading)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Files

Commands in this file are run from the repo root (`k8s-template/`).

| File | Purpose |
| ---- | ------- |
| `grafana-mcp/README.md` | This file |
| `grafana-mcp/values.yaml` | Upstream chart values (method A) |
| `grafana-mcp/default-values.yaml` | Upstream defaults for reference (`helm show values grafana-community/grafana-mcp --version 0.27.2 > default-values.yaml`) |
| `grafana-mcp/custom/values.yaml` | Custom chart defaults (method B) |
| `grafana-mcp/custom/Chart.yaml` | Chart metadata, `appVersion` tracks the binary/image tag |
| `grafana-mcp/custom/.helmignore` | Keeps `values.local.yaml` out of `helm package` |
| `grafana-mcp/custom/templates/deployment.yaml` | Deployment + probes + `envFrom` Secret |
| `grafana-mcp/custom/templates/service.yaml` | ClusterIP Service (MCP endpoint) |
| `grafana-mcp/custom/templates/secret.yaml` | Optional Secret rendered from `plainText` |
| `grafana-mcp/custom/templates/serviceaccount.yaml` | Optional ServiceAccount |
| `grafana-mcp/custom/templates/ingress.yaml` | Subpath ingress under the shared `nginx` class |
| `grafana-mcp/custom/templates/_helpers.tpl` | Naming, labels, placeholder validation |
| `grafana-mcp/custom/templates/NOTES.txt` | Post-install output |

No chart dependency, no subchart: `helm dependency build` is never needed.

---

## Choose an Installation Method

| Method | Directory | Use when |
| ------ | --------- | -------- |
| **A. Upstream chart** | `grafana-mcp/values.yaml` | The node can pull `docker.io/grafana/mcp-grafana`, and the default image entrypoint + `extraArgs` fits |
| **B. Custom chart** | `grafana-mcp/custom/` | You control the container `command` (air-gapped mirror image, base-URL subpath, flags the upstream chart cannot express) |

Both produce the same objects: Deployment, ClusterIP Service, Ingress, and a Secret
reference for the Grafana service-account token. **Neither chart writes a credential
into the manifest** unless you deliberately use `secret.create` + `plainText` (method B) —
prefer the pre-created Secret.

> **Warning:** What is live on the production cluster right now was installed with
> method B (`helm upgrade --install grafana-mcp ./custom -n grafana`, revision 4,
> `helm get metadata` reports `APPLY_METHOD: client-side apply`). It is not managed by
> Argo CD or Fleet. Before re-installing, read [Aligning With the Existing Release](#aligning-with-the-existing-release).

---

## Prerequisites

- Kubernetes 1.22+ (Ingress `pathType: ImplementationSpecific`), Helm 3+
- NGINX Ingress Controller with the shared `nginx` ingress class
- The **Grafana instance the MCP server talks to** must already exist. Grafana MCP
  makes no sense pointed at nothing; the values assume
  `http://grafana-prd.grafana:3000` (Grafana 9+ is required for datasource tools)
- Container image. Either the mirror `reg.magnecomp.com/<project>/grafana-grafana-mcp:<tag>`,
  or a local build of upstream (see [Build the Mirror Image](#build-the-mirror-image))
- The image-pull Secret in the target namespace:

```bash
kubectl -n grafana create secret docker-registry reg-magnecomp-secret \
  --docker-server=reg.magnecomp.com \
  --docker-username=<registry-user> \
  --docker-password=<registry-password>
```

- A **Grafana service-account token** (`Editor`, or scoped down per the upstream RBAC
  table in [References](#references)), stored out-of-band:

```bash
kubectl -n grafana create secret generic grafana-mcp-secret \
  --from-literal=GRAFANA_URL="http://grafana-prd.grafana:3000/grafana" \
  --from-literal=GRAFANA_SERVICE_ACCOUNT_TOKEN="<grafana-service-account-token>"
```

For **method A**, create a separate Secret holding only the token — that chart reads
`grafana.apiKeySecret` for it and takes `GRAFANA_URL` from values:

```bash
kubectl -n grafana create secret generic grafana-mcp-api-key \
  --from-literal=api-key="<grafana-service-account-token>"
```

---

## Installation

### Method A — Upstream `grafana-mcp` chart

The chart in the `grafana` repo is marked `deprecated: true` (as of 0.3.1) and moved to
[grafana-community/helm-charts](https://github.com/grafana-community/helm-charts). Both
repos still publish it and accept this values file; prefer `grafana-community`.

1. Add the repo and list versions:

   ```bash
   helm repo add grafana-community https://grafana-community.github.io/helm-charts
   helm repo update
   helm search repo grafana-community/grafana-mcp --versions | head
   ```

2. Confirm that chart version's `values.yaml` still exposes every key used by
   `grafana-mcp/values.yaml` — Helm applies unknown keys silently, so a renamed key simply
   stops doing anything:

   ```bash
   export LC_ALL=C   # sort/comm must agree, or comm reports "not in sorted order"
   helm show values grafana-community/grafana-mcp --version <CHART_VERSION> > /tmp/upstream-values.yaml
   comm -13 <(grep -oE '^[a-zA-Z]+:' /tmp/upstream-values.yaml | sort -u) \
            <(grep -oE '^[a-zA-Z]+:' grafana-mcp/values.yaml | sort -u)
   ```

   Expected output: nothing. Any line is a key this values file sets that the chart version
   does not know about. Pin `--version <CHART_VERSION>` on the install; the file is written
   against 0.27.2 (appVersion 2.0.2) and also renders clean against grafana/grafana-mcp 0.3.1.

3. Install from the repo root:

   ```bash
   helm upgrade --install grafana-mcp grafana-community/grafana-mcp \
     --namespace grafana \
     --version <CHART_VERSION> \
     -f grafana-mcp/values.yaml
   ```

   Real credentials go in a gitignored overlay like any other stack:
   `-f grafana-mcp/values.local.yaml`.

### Method B — Custom chart in this directory

1. Copy the values to a local file (gitignored by the repo-root `.gitignore`:
   `*.local.yaml`) and fill in the placeholders there:

   ```bash
   cp grafana-mcp/custom/values.yaml grafana-mcp/custom/values.local.yaml
   # edit values.local.yaml: image.repository/tag, ingress.hosts[0].host,
   # secret.existingSecret
   ```

   Leave the placeholders in `values.yaml`. The `-n grafana` in the commands below is the
   namespace the MCP release lives in; the MCP server reaches Grafana over the Service DNS
   name in `GRAFANA_URL`, so the two do not have to match.

2. Render before applying. This is also your blast-radius check against the live release:

   ```bash
   helm template grafana-mcp grafana-mcp/custom \
     -n grafana -f grafana-mcp/custom/values.local.yaml | less
   ```

3. Install:

   ```bash
   helm upgrade --install grafana-mcp grafana-mcp/custom \
     -n grafana \
     -f grafana-mcp/custom/values.local.yaml
   ```

4. `helm get metadata grafana-mcp -n grafana 2>/dev/null` confirms the release is
   `deployed` and `CHART: mcp-grafana`. NOTES.txt then prints the MCP endpoint and the
   verify commands.

### Aligning With the Existing Release

Skip this when installing into a fresh namespace where the release name does not exist.

Namespace `grafana` already holds `grafana-mcp-mcp-grafana-*` objects (Deployment, Service,
Ingress, Secret, ServiceAccount) owned by release `grafana-mcp`. `custom/templates/_helpers.tpl`
reproduces those names under the same release name, so the chart takes them over instead of
installing a parallel stack: an **upgrade adopts them, and a `helm install` under that name
fails** with `invalid ownership metadata`. Three differences show up in the first upgrade —
check them with a dry run before applying:

```bash
helm install grafana-mcp grafana-mcp/custom -n grafana --dry-run \
  -f grafana-mcp/custom/values.local.yaml > /tmp/new.yaml
helm get manifest grafana-mcp -n grafana > /tmp/live.yaml
diff /tmp/live.yaml /tmp/new.yaml
```

| Difference | Effect |
| ---------- | ------ |
| `serviceAccountName: grafana-mcp-mcp-grafana` + `automountServiceAccountToken: false` | The live Pods run under `default` even though the old chart created the ServiceAccount. This changes the pod spec, so the pods restart |
| `revisionHistoryLimit: 5` | Live value is 10; ReplicaSets beyond 5 are pruned |
| `securityContext: {}` is no longer emitted | No behaviour change, an empty map does nothing either way |

Anything the live Deployment carries that the chart does not model has to be added to values,
because `helm upgrade` rewrites the whole object from the chart output. A `kubectl edit
deploy` hotfix survives only until the next upgrade.

### Build the Mirror Image

Build only when the nodes cannot pull `docker.io/grafana/mcp-grafana`. Push under
`<project>/grafana-grafana-mcp` and the values in this directory line up, including the
binary path `./mcp-grafana` (`WORKDIR /app`, `USER mcp-grafana` uid 1000).

```bash
git clone --depth 1 https://github.com/grafana/mcp-grafana /tmp/mcp-grafana
cd /tmp/mcp-grafana
docker build \
  -t reg.magnecomp.com/<project>/grafana-grafana-mcp:<image_tag> .
docker push reg.magnecomp.com/<project>/grafana-grafana-mcp:<image_tag>
```

The upstream Dockerfile has no `HEALTHCHECK`, so a probe has to be supplied by the chart
(`probes.*` in method B, `readinessProbe` in method A).

---

## Values Reference

### `grafana-mcp/values.yaml` (method A — upstream chart)

| Key | Description | Default in this repo |
| --- | ----------- | -------------------- |
| `replicas` | Replica count | `1` |
| `image.registry` / `repository` / `tag` | Pinned image; **a tag is mandatory** (upstream `appVersion: latest`), and `Always` is not a substitute for pinning | `reg.magnecomp.com` / `<project>/grafana-grafana-mcp` / `<IMAGE_TAG>` |
| `imagePullSecrets` | Mirror needs `reg-magnecomp-secret` | `[reg-magnecomp-secret]` |
| `grafana.url` | Grafana API base **inside** the cluster (end users use the public URL). Keep the `/grafana` suffix only if Grafana itself serves under that subpath | `http://grafana-prd.grafana:3000/grafana` |
| `grafana.apiKey` | Inline token — leave `""`, it lands in the release secret | `""` |
| `grafana.apiKeySecret.name` / `.key` | Pre-created Secret holding the token | `grafana-mcp-api-key` / `api-key` |
| `disabledCategories` | `--disable-<cat>` flags; the chart generates the flag name from each entry | `[oncall]` |
| `extraArgs` | Raw appended arguments (transport, address, host allowlist) | `-t streamable-http --address 0.0.0.0:8000 --allowed-hosts '*'` |
| `env` | Plain extra environment, e.g. `GRAFANA_ORG_ID` | `{}` |
| `envValueFrom` | Environment sourced from Secret/ConfigMap refs — put `MCP_GRAFANA_SERVER_TOKEN` here, not in `env` | `{}` (`MCP_GRAFANA_SERVER_TOKEN` example is commented out) |
| `readinessProbe` / `livenessProbe` / `startupProbe` | Disabled by default: `Host`/`Origin` validation can 403 `httpGet` probes | `{}` |
| `containerSecurityContext` / `securityContext` | Upstream ships uid 1000, `readOnlyRootFilesystem: true` | upstream defaults kept |
| `ingress.enabled` / `className` / `hosts` / `annotations` | Subpath exposure under the shared `nginx` class | enabled, `nginx`, `wn-a-prd-ai-k8s.tlnw.magnecomp.com` + `/grafana-mcp(/|$)(.*)` |

### `grafana-mcp/custom/values.yaml` (method B)

| Key | Description | Default in this repo |
| --- | ----------- | -------------------- |
| `fullnameOverride` | Empty keeps `<release>-mcp-grafana`, which reproduces the live object names under release `grafana-mcp` | `""` |
| `image.repository` / `tag` / `digest` | Whole reference, no separate registry key. **`tag: main` + `pullPolicy: Always` is what the live release runs — a re-deploy can pull a different binary than the one running today.** `digest` is the only real pin | `reg.magnecomp.com/<project>/grafana-grafana-mcp` / `<IMAGE_TAG>` / `""` |
| `command` | Replaces the image `ENTRYPOINT` (`["/app/mcp-grafana","--transport","sse",...]`), and must name the binary the mirror ships (`./mcp-grafana` against WORKDIR `/app`) | `./mcp-grafana -t streamable-http --address 0.0.0.0:8000 --allowed-hosts '*' --tls-skip-verify` |
| `args` | Appended after `command`, rendered only when non-empty | `[]` |
| `containerPort` / `service.port` / `service.targetPort` | Container listen port / Service port / port the Service targets | `8000` / `8008` / `8000` |
| `env` | Plain extra environment on the container, e.g. `GRAFANA_ORG_ID` | `{}` |
| `extraEnvVars` | Full EnvVar entries, for a Secret ref that is not in `secret.existingSecret` (e.g. `MCP_GRAFANA_SERVER_TOKEN`) | `[]` |
| `secret.existingSecret` | Pre-created `envFrom` Secret (recommended). `secret.create: false` requires a non-placeholder value here | `grafana-mcp-secret` |
| `secret.create` / `secret.name` | Renders a Secret from `plainText` — the live release's approach, and why its token is readable from the release. The default name matches the live `grafana-mcp-mcp-grafana-env` | `false` / `""` |
| `plainText` | k/v input for `secret.create: true` only | `{}` |
| `serviceAccount.create` / `name` | Must stay a bool/string: `{}` for `create` once rendered `serviceAccountName: map[create:true name:]` and failed `helm install` outright | `true` / `""` |
| `ingress.*` | Host + regex subpath, `rewrite-target: /$2`, `use-regex`, `proxy-body-size: "0"` for large tool responses | `<INGRESS_HOST>` / `/grafana-mcp(/\|$)(.*)` |
| `revisionHistoryLimit` | Bounds the persisted Helm release secrets, each of which holds the token when `secret.create: true` | `5` |
| `probes.enabled` / `path` / `port` | `httpGet` probes off by default: the image has no HEALTHCHECK and Host validation 403s a probe's default `Host` (`port: 0` means `containerPort`) | `false` / `/healthz` / `0` |
| `volumes` / `volumeMounts` | For `--tls-ca-file` or `GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE` | `[]` |
| `podSecurityContext` / `containerSecurityContext` | Empty to match the live Deployment. `readOnlyRootFilesystem` also needs an emptyDir at `/tmp` | `{}` |

Every `*.local.yaml` is gitignored and never packaged (see `custom/.helmignore`).

---

## Calling the Server

The MCP endpoint is the ingress host, the subpath, and the transport endpoint path
(`--endpoint-path`, default `/mcp`):

```text
http://<ingress-host>/<subpath>/mcp
```

With `rewrite-target: /$2` the subpath is stripped before proxying, so the server sees
`/mcp`. When a client cannot connect through the ingress, test through the Service first to
separate rewrite problems from server problems:

```bash
kubectl -n grafana port-forward svc/grafana-mcp-mcp-grafana 8008
# http://127.0.0.1:8008/mcp
```

Client config (Open WebUI, Claude Desktop, Cursor — `streamable-http` transport):

```json
{
  "mcpServers": {
    "grafana": {
      "type": "streamable_http",
      "url": "http://<ingress-host>/<subpath>/mcp"
    }
  }
}
```

**In this URL the `/mcp` suffix is required, and no trailing slash is allowed.** Clients
that only speak SSE point at `/<subpath>/sse` instead.

Set `MCP_GRAFANA_SERVER_TOKEN` and every request must carry
`Authorization: Bearer <token>`; without it the server logs a security error and accepts
unauthenticated calls:

```bash
kubectl -n grafana create secret generic grafana-mcp-server-token \
  --from-literal=MCP_GRAFANA_SERVER_TOKEN="<random-long-token>"
```

Without `GRAFANA_ORG_ID` the logs fill with `No org ID found in request headers`
warnings; either set `GRAFANA_ORG_ID` in the Secret, or pass the
`X-Grafana-Org-Id` header per request. The live deployment does not set it.

---

## Verify

```bash
helm status grafana-mcp -n grafana
kubectl -n grafana get deploy,pod,svc,ingress,secret -l app.kubernetes.io/instance=grafana-mcp
kubectl -n grafana logs deploy/grafana-mcp-mcp-grafana --tail=20
```

Expected output: pod `1/1 Running`; logs end with `connected to proxied MCP servers`
after a client connects. (Installed by method B, labels are `app=mcp-grafana`.)

Health endpoint. The image is Debian-slim without a shell client, so run the check from a
throwaway pod instead of `kubectl exec`:

```bash
kubectl -n grafana run gmcp-healthz --rm -it --restart=Never --image=curlimages/curl:8 -- \
  curl -sf http://grafana-mcp-mcp-grafana.grafana.svc:8008/healthz
```

Expected output: `ok` (the literal body of `/healthz`). It exists only under the SSE and
`streamable-http` transports, and is always served at the root, never under `--base-path`.
A probe failure here usually means `--allowed-hosts` rejects the request's `Host` header.

Confirm Grafana's own API is reachable from that namespace — `--tls-skip-verify` in the live
`command` is only needed when TLS to Grafana would otherwise fail:

```bash
kubectl -n grafana run gmcp-check --rm -it --restart=Never --image=curlimages/curl:8 -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://grafana-prd.grafana:3000/grafana/api/health
```

Expected output: `200`. Both pods pull from Docker Hub; on nodes that cannot reach it, use a
mirrored curl image.

---

## Upgrading

With a pinned `image.tag` and `pullPolicy: IfNotPresent`, `helm upgrade` rolls the pods only
when the rendered pod spec changes, and the image it rolls to is the image you tagged. Build
the new mirror image first, then bump the tag:

```bash
helm upgrade --install grafana-mcp grafana-mcp/custom -n grafana \
  -f grafana-mcp/custom/values.local.yaml --set image.tag=<image_tag>
kubectl -n grafana rollout status deploy/grafana-mcp-mcp-grafana
```

With the live configuration (`tag: main` + `pullPolicy: Always`) there is nothing to bump, and
a pod that restarts for any reason — eviction, node reboot, OOM — comes back on whatever
`main` points at that day, with no `helm upgrade` and no `helm history` entry behind it.

Roll back instead when the new image is fine but the config broke:

```bash
helm history grafana-mcp -n grafana
helm rollback grafana-mcp <REVISION> -n grafana
```

> **Warning:** with `secret.create: true` the token is part of the chart values, so it is
> written into the release secret — and `revisionHistoryLimit` keeps a release secret **per
> revision**, each holding a copy. `helm get values --all` prints it, and rollback does not
> clear the older revisions. Create the credential Secret out of band and leave
> `secret.create: false`; a token that has already landed in revision history should be
> rotated, which is the only real cleanup.

---

## Uninstall

```bash
helm uninstall grafana-mcp -n grafana
```

No PVCs are involved (stateless server), so nothing else lingers except the
out-of-band Secrets:

```bash
kubectl -n grafana delete secret grafana-mcp-secret grafana-mcp-server-token
```

---

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `helm install` fails: `serviceAccountName: Invalid value: "map[create:true name:]"` | `serviceAccount.create` was left as an empty map, so Helm stringified it. Hand-written chart bug (see live release revision 1). Use the `{}`/quoted-string defaults in method B or the explicit strings upstream uses. |
| Pod `1/1 Running`, tools return `404 page not found` | Wrong base URL or wrong path. `GRAFANA_URL` must be the root of the Grafana API, so `http://grafana-prd.grafana:3000/grafana` when Grafana itself is served off `/grafana`. |
| Client gets `404`/`421` from the ingress though the pod is healthy | `--allowed-hosts` rejects the proxy `Host`, or the rewrite ate the subpath. The working config is `use-regex: "true"` + `rewrite-target: /$2` + regex path `<subpath>(/\|$)(.*)`, with `--allowed-hosts '*'` given the proxy validates `Host`; an exact host list makes the rewrite cleaner to reason about. |
| Pod restarts immediately, probes fail with `403` | `httpGet` probes send `Host: <pod-ip>:8000`, which is outside the default `--allowed-hosts`. Use `tcpSocket` probes or add the pod hostnames, or run `/healthz` on a separate listener with `--healthz-address :8080` and probe port 8080. |
| `x509: certificate signed by unknown authority` calling Grafana over HTTPS | Do not reach for `--tls-skip-verify` (it disables verification entirely). Mount the CA, set `--tls-ca-file`, and add a volume with `volumes`/`volumeMounts` (method A exposes both). |
| Logs spam `No org ID found in request headers or environment variables, using default org` | Cosmetic but noisy: set `GRAFANA_ORG_ID` in the Secret, or send `X-Grafana-Org-Id` per request. |
| Tools answer `403` / empty lists | The service-account token lacks RBAC. Quickest fix is the `Editor` role; granular fix is the action/scope table in the upstream README (`datasources:read`, `dashboards:read`, `datasources:query`, ...). |
| ImagePullBackOff `pull access denied for reg.magnecomp.com/...` | `imagePullSecrets` missing from values, or `reg-magnecomp-secret` was not created in this namespace. Recreate it ([Prerequisites](#prerequisites)). |
| `-t streamable-http` accepted but the client cannot connect | The image entrypoint defaults to `--transport sse`. Method B overrides `command` for this reason; method A must pass `-t streamable-http` in `extraArgs`. |
| `helm template` fails with `the image reference ... still contains a placeholder` or `ingress.hosts[0].host is the placeholder` | Expected guards in `custom/templates/_helpers.tpl`. Fill `values.local.yaml`, or pass `--set` on the command line. |
| Hotfix made with `kubectl edit deploy` disappeared | Helm's declarative fields overwrite manual edits on the next `helm upgrade`, and drift is invisible on the cluster. Commit the change into mirror `values.yaml` instead. |

---

## References

- Upstream server (flags, tool list, RBAC table): <https://github.com/grafana/mcp-grafana>
- Upstream Helm chart, the maintained location:
  <https://github.com/grafana-community/helm-charts> (repo
  `https://grafana-community.github.io/helm-charts`). The copy in
  <https://github.com/grafana/helm-charts/tree/main/charts/grafana-mcp> is deprecated from
  chart 0.3.1. `helm show readme grafana-community/grafana-mcp --version <CHART_VERSION>`
  prints the generated parameter table
- MCP transport spec (streamable HTTP): <https://modelcontextprotocol.io/specification>
- In this repo: `grafana-mcp/values.yaml` (method A), `grafana-mcp/custom/` (method B),
  `superset/mcp.yaml` (the same idea as a plain manifest, port 5008)
