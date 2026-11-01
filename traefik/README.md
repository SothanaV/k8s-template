# Traefik ingress controller (`kube-system/traefik`)

Traefik v3 installed as the Helm release `traefik` in `kube-system`. It is the
cluster's **only** ingress controller: IngressClass `traefik` is the cluster
default and no other class exists (`rke2-ingress-nginx` was removed). Routes come
from the **NGINX-compatible provider** (`providers.kubernetesIngressNGINX`), so
Ingresses that carry `nginx.ingress.kubernetes.io/rewrite-target`, `use-regex`,
`auth-type`, `proxy-body-size` … keep working unchanged. Exposed as `NodePort`
`30080`/`30443`, so it needs no load balancer.

Install only lives here. Everything else — current state, the 97-Ingress audit,
proof techniques, the NGINX cut-over, troubleshooting, outstanding work — is in
**[CUTOVER.md](CUTOVER.md)**.

## Table of Contents

- [Files](#files)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Verify](#verify)
- [Values Reference](#values-reference)
- [Using the Ingress Class](#using-the-ingress-class)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Common install failures](#common-install-failures)
- [References](#references)

---

## Files

| File | Purpose |
| ---- | ------- |
| `values.yaml` | Chart overrides (3 replicas, IngressClass `traefik` as cluster default, NGINX provider, NodePort `30080`/`30443`, control-plane tolerations) |
| `README.md` | Install guide (this file) |
| `CUTOVER.md` | Cluster state, cut-over record, audit, troubleshooting |

Chart `traefik-42.2.0` ships app version `v3.7.16` — **pin `--version 42.2.0`** so
the image tag stays `docker.io/traefik:v3.7.16`. Older scripts here don't pin it,
which is how `v3.7.12` silently became `v3.7.16`. There is no `default-values.yaml`
because the upstream default set is large; dump it when you need to look something
up:

```bash
helm show values traefik/traefik --version 42.2.0 > /tmp/traefik-default-values.yaml
```

---

## Prerequisites

- Helm 3 with the chart repo added:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik --versions | head -n 10
```

- NodePort `30080` and `30443` free on every node (default range is `30000-32767`).
  They used to belong to `rke2-ingress-nginx-controller`, which is deleted:

```bash
kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="NodePort")
  | . as $s | .spec.ports[] | select(.nodePort==30080 or .nodePort==30443)
  | "\(.nodePort)  \($s.metadata.namespace)/\($s.metadata.name)"'
```

  Expected output: nothing. Anything else is a port owner that must be removed
  first — the API then rejects the whole install
  (`spec.ports[0].nodePort … provided port is already allocated`).

- No namespace to create — this release lives in `kube-system`.

> **Warning**: the chart installs the `traefik.io` CRDs (IngressRoute, Middleware,
> TLSOption, …) from its `crds/` directory. Helm installs those once, never
> upgrades them, and never removes them — see [Upgrade](#upgrade).

---

## Install

Run from the `traefik/` directory so the relative `-f` path resolves.

```bash
helm upgrade -i traefik traefik/traefik \
  -n kube-system --version 42.2.0 \
  -f values.yaml --wait --atomic --timeout 5m
```

`helm upgrade -i` covers the first install and every later change. **The
subcommand is `upgrade`, not `update` — `helm update` does not exist.**
`--atomic` rolls the release back automatically if the rollout never becomes Ready.

> **Warning**: `helm upgrade` without `-f values.yaml` replaces every
> user-supplied value with chart defaults. It does not fail loudly — Traefik comes
> back and every Ingress 404s. Start from what is live when in doubt:
>
> ```bash
> helm -n kube-system get values traefik -o json > /tmp/current.json
> ```

---

## Verify

```bash
kubectl -n kube-system get pods,svc -l app.kubernetes.io/name=traefik
kubectl get ingressclass
```

Expected: 3 Traefik pods `Running`, Service `traefik` `NodePort` on
`80:30080, 443:30443`, and one class `traefik` with controller
`traefik.io/ingress-controller`.

Check the `targetPort`s explicitly. `get svc` prints `80:30080, 443:30443`
identically whether `targetPort` is `web` or the literal `80`, and only
`web`/`websecure` point at the ports Traefik listens on (`8000`/`8443`):

```bash
kubectl -n kube-system get svc traefik \
  -o jsonpath='{range .spec.ports[*]}{.name}={.targetPort} nodePort={.nodePort}{"\n"}{end}'
```

Expected output:

```
web=web nodePort=30080
websecure=websecure nodePort=30443
```

`targetPort: 80`/`443`, or port names renamed to `http`/`https`, means the Service
was edited outside Helm and every NodePort connection will get `connection
refused`. Fix it with a values-based `helm upgrade`, never by re-editing.

Confirm the providers Traefik actually started with — container args are the
source of truth:

```bash
kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'providers|entryPoints'
```

Expected:

```
--entryPoints.web.address=:8000/tcp
--entryPoints.websecure.address=:8443/tcp
--entryPoints.websecure.http.tls=true
--providers.kubernetescrd
--providers.kubernetesingressnginx
--providers.kubernetesingressnginx.ingressClass=traefik
--providers.kubernetesingressnginx.ingressClassByName=true
--providers.kubernetesingressnginx.publishservice=kube-system/traefik
--providers.kubernetesingressnginx.watchIngressWithoutClass=false
```

There must be **no** `--providers.kubernetesingress` line; if it appears, two
providers are watching Ingresses and every route is duplicated.

Smoke test with a throwaway app:

```bash
kubectl -n kube-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
spec:
  replicas: 1
  selector:
    matchLabels: { app: whoami }
  template:
    metadata:
      labels: { app: whoami }
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
spec:
  selector: { app: whoami }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
spec:
  ingressClassName: traefik
  rules:
    - host: whoami.example.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: whoami, port: { number: 80 } } }
EOF
```

```bash
curl -s -H "Host: whoami.example.local" http://<NODE_IP>:30080/    # -> whoami body
kubectl -n kube-system delete deploy,svc,ingress whoami
```

`/ping` is on the internal `traefik` entry point (8080), which the Service does not
expose. It separates "Traefik is down" from "routing is wrong", because it answers
even when no Ingress matches:

```bash
kubectl -n kube-system port-forward deploy/traefik 8080:8080
curl -s http://127.0.0.1:8080/ping        # -> OK
```

The dashboard and `/api/*` answer `404` with these values — that is expected, not
a broken install. `--api.dashboard=true` is present but binds the API to no entry
point; [CUTOVER.md → Dashboard and API](CUTOVER.md#dashboard-and-api) has the three
ways to switch it on.

---

## Values Reference

`values.yaml`, matching the live release:

| Parameter | Description | Value here |
| --------- | ----------- | ---------- |
| `deployment.replicas` | Number of Traefik pods | `3` |
| `ingressClass.enabled` | Create an IngressClass | `true` |
| `ingressClass.isDefaultClass` | Make `traefik` the cluster default | `true` |
| `ingressClass.name` | IngressClass object name | `traefik` |
| `ports.web.nodePort` | NodePort for HTTP (`:8000`) | `30080` |
| `ports.websecure.nodePort` | NodePort for HTTPS (`:8443`) | `30443` |
| `service.spec.type` | Service type | `NodePort` |
| `providers.kubernetesIngress.enabled` | Plain Ingress provider — off, the NGINX provider owns Ingress objects | `false` |
| `providers.kubernetesIngressNGINX.enabled` | NGINX-compatible Ingress provider | `true` |
| `providers.kubernetesIngressNGINX.ingressClass` | Class handled by this controller | `traefik` |
| `providers.kubernetesIngressNGINX.ingressClassByName` | Match the class by name, not only by controller value | `true` |
| `providers.kubernetesIngressNGINX.publishService.enabled` | Write the front-end Service into Ingress status | `true` |
| `providers.kubernetesIngressNGINX.watchIngressWithoutClass` | Ignore Ingresses with no class | `false` |
| `tolerations` | Allow pods on tainted nodes | control-plane `NoSchedule` **and** etcd `NoExecute` |

Both tolerations are required — tolerating only the control-plane taint is a no-op
([CUTOVER.md → Running on control-plane nodes](CUTOVER.md#running-on-control-plane-nodes)).

Not set here, worth knowing:

| Parameter | Chart default | Effect here |
| --------- | ------------- | ----------- |
| `providers.kubernetesCRD.enabled` | `true` | `IngressRoute`/`Middleware` still work alongside the NGINX provider |
| `providers.kubernetesIngressNGINX.controllerClass` | `k8s.io/ingress-nginx` | Untouched; `ingressClassByName: true` is what makes `traefik` match |
| `ports.traefik.expose.default` | `false` | Dashboard/`/ping` stay cluster-internal |
| `resources` | unset | No requests/limits — set them before sharing nodes with etcd |
| `affinity` | `{}` | No anti-affinity; 3 replicas can land on one node |
| `podDisruptionBudget.enabled` | `false` | No PDB |
| `logs.access` | off | No per-request log, so you cannot see which router served a request |

---

## Using the Ingress Class

`traefik` is the default class and `watchIngressWithoutClass: false`, so an Ingress
with no class gets `traefik` at admission, while one explicitly set to anything
else is ignored forever. Say it out loud anyway — one line, and it survives a
review:

```yaml
spec:
  ingressClassName: traefik
```

`publishService.enabled: true` writes the front-end Service into
`Ingress.status`. Because that Service is `NodePort`, the address written is the
**ClusterIP** — valid-looking but useless for DNS automation. Point clients at
`<NODE_IP>:30080` / `<NODE_IP>:30443`, or publish real addresses with
`providers.kubernetesIngressNGINX.publishService.addresses`.

---

## Upgrade

```bash
helm -n kube-system history traefik | tail -3        # record the current revision
helm upgrade traefik traefik/traefik \
  -n kube-system --version <NEW_CHART_VERSION> \
  -f values.yaml --wait --atomic --timeout 5m
helm -n kube-system rollback traefik <REV>           # if you need to back out by hand
```

`crds/` is a one-time directory — Helm will not update the `traefik.io` CRDs. When
the new chart needs newer CRDs, apply them yourself first:

```bash
helm pull traefik/traefik --version <NEW_CHART_VERSION> --untar --untardir /tmp
kubectl apply --server-side -f /tmp/traefik/crds/
```

Rollout is a rolling update of 3 pods and existing routes keep serving; expect a
handful of dropped in-flight requests during the roll.

---

## Uninstall

> **Warning**: Traefik serves **every** Ingress in the cluster. Uninstalling it
> takes all public hostnames dark and there is no NGINX left to catch the traffic.
> Stage a replacement front end first.

```bash
helm uninstall traefik -n kube-system
```

The `traefik` IngressClass and the `traefik.io` CRDs stay behind (Helm never
removes CRDs). Do **not** `kubectl delete ns kube-system` — this release lives
there, but so does everything else. Before deleting the CRD *types*, confirm
nothing still uses them:

```bash
kubectl get crd | grep traefik.io
kubectl get ingressroute,middleware -A
```

---

## Common install failures

- **`helm: command 'update' is not valid`** — it is `helm upgrade -i traefik
  traefik/traefik -n kube-system --version 42.2.0 -f values.yaml`.
- **`Service "traefik" is invalid: spec.ports[0].nodePort: Invalid value: 30080:
  provided port is already allocated`** — something else still owns the port (this
  is how release revision 1 failed, while the old nginx Service was still there).
  The install is rejected whole, so nothing partial is left behind. Free the port,
  re-run, and read `helm -n kube-system history traefik` for failed revisions.
- **Everything 404s after an upgrade that "succeeded"** — you ran `helm upgrade`
  without `-f values.yaml`, so chart defaults replaced your values. Diff against
  `helm -n kube-system get values traefik -o json` and re-apply.
- **`connection refused` on every `3xxxx` port while pods are `Ready`** — the
  Service was hand-edited (`targetPort` no longer `web`/`websecure`). Read it with
  the `jsonpath` in [Verify](#verify); re-deploy from `values.yaml` to fix. A
  `kubectl patch` fixes one incident and guarantees the next.
- **404 on a path you are sure is configured** — probe the path from the Ingress,
  not `/`: a rule written `/sonarqube(/|$)(.*)` answers on `/sonarqube/` and 404s
  on `/`. And note Traefik's 404 body is byte-identical to any Go app's
  (`404 page not found`, 19 bytes) — [CUTOVER.md → how do I know Traefik is the one
  answering](CUTOVER.md#how-do-i-know-traefik-is-the-one-answering) is the method.
- **Anything else** — [CUTOVER.md → Troubleshooting](CUTOVER.md#troubleshooting)
  (certificates, wildcards, webhooks, firewall vs kube-proxy, `rke2-ingress-nginx`
  coming back).

---

## References

- [Traefik Helm chart repository](https://github.com/traefik/traefik-helm-chart)
- [Traefik VALUES reference](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/VALUES.md)
- [Traefik Kubernetes Ingress NGINX provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/)
- [Traefik dashboard and API](https://doc.traefik.io/traefik/operations/dashboard/)
