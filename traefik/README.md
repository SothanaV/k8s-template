# Traefik (`traefik-private`)

Traefik v3 as an ingress controller in the `traefik-private` namespace, fronting
Ingress objects of class `traefik-private` through the NGINX-compatible provider
(`providers.kubernetesIngressNGINX`) instead of the plain Kubernetes Ingress
provider. Exposed as `NodePort`, so it works without MetalLB.

## Table of Contents

- [Files](#files)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Verify](#verify)
- [Values Reference](#values-reference)
- [Using the Ingress Class](#using-the-ingress-class)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Files

| File | Purpose |
| ---- | ------- |
| `values.yaml` | Chart overrides (3 replicas, IngressClass `traefik-private`, NGINX provider, NodePort 32080/32443) |
| `README.md` | This file |

Chart `traefik-41.4.0` ships app version `v3.7.12` — pin `--version 41.4.0` so
the image tag stays `docker.io/traefik:v3.7.12`.

No `default-values.yaml` here; the upstream default set is large. Dump it when
you need to look something up:

```bash
helm show values traefik/traefik --version 41.4.0 > /tmp/traefik-default-values.yaml
```

---

## Prerequisites

- Helm 3+ with the Traefik repo added:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

- NodePort range is the default Kubernetes `30000-32767`: `32080` and `32443`
  must be free on every node and open in the datacenter firewall.
- The namespace, created once:

```bash
kubectl create ns traefik-private
```

> **Warning**: this chart installs the `traefik.io` CRDs (IngressRoute,
> Middleware, TLSOption, …) from its `crds/` directory. Helm never removes CRDs
> on uninstall, and it does not upgrade them — see [Upgrade](#upgrade).

---

## Installation

Run from `traefik/` so the relative `-f` path resolves.

### 1. Check available versions

```bash
helm search repo traefik/traefik --versions | head -n 10
```

### 2. Install

```bash
helm upgrade -i traefik-private traefik/traefik \
  -n traefik-private --version 41.4.0 \
  -f values.yaml
```

`helm upgrade -i` covers the first install and every later change. **The
subcommand is `upgrade`, not `update` — `helm update` does not exist.**

---

## Verify

```bash
kubectl -n traefik-private get pods,svc,ingressclass
```

Expected output: 3 `traefik-private` pods `Running`, the `traefik-private`
Service of type `NodePort` on `80:32080, 443:32443`, and the IngressClass
`traefik-private` with controller `traefik.io/ingress-controller`.

Then check the `targetPort`s. `get svc` prints `80:32080, 443:32443` identically
whether `targetPort` is `web` or the literal `80`, but only `web`/`websecure`
point at the ports Traefik listens on (`8000`/`8443`):

```bash
kubectl -n traefik-private get svc traefik-private \
  -o jsonpath='{range .spec.ports[*]}{.name}={.targetPort} {" "}{end}{"\n"}'
```

Expected output: `web=web websecure=websecure`. Port `name: http`/`https` or
`targetPort: 80`/`443` means someone edited the Service outside Helm — every
NodePort connection then fails with `connection refused`. See
[Troubleshooting](#troubleshooting).

> **Warning**: The `targetPort` and port `name` fields are the usual casualties
> of editing this Service in Lens or with `kubectl edit`. A values-based
> `helm upgrade` is the only fix; re-editing brings the outage back.

Confirm the providers Traefik actually started with — the container args are the
source of truth:

```bash
kubectl -n traefik-private get deploy traefik-private -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep providers
```

Expected output: `--providers.kubernetescrd` and
`--providers.kubernetesingressnginx.ingressClass=traefik-private`. There must be
no plain `--providers.kubernetesingress` entry.

Smoke test (echo server + Ingress on this class):

```bash
kubectl -n traefik-private apply -f - <<'EOF'
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
  ingressClassName: traefik-private
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
curl -s -H "Host: whoami.example.local" http://<NODE_IP>:32080/
```

Expected output: the whoami body listing `Hostname` and headers. **Use a worker
node's IP: where the datacenter firewall opens service ports only on workers,
control-plane IPs drop `3xxxx` traffic silently — a timeout, not a clean
refusal.** Remove the test objects afterwards:

```bash
kubectl -n traefik-private delete deploy,svc,ingress whoami
```

`/ping` is on the `traefik` entry point (8080), which is intentionally not
exposed by the Service. Reach it locally:

```bash
kubectl -n traefik-private port-forward deploy/traefik-private 8080:8080
curl -s http://127.0.0.1:8080/ping
```

Expected output: `OK`. Use this to separate "Traefik is down" from "routing is
wrong" — `/ping` answers even when no Ingress matches.

**The dashboard and `/api/*` are dead with these values.** The chart ships
`api.dashboard: true` but nothing else, which renders only
`--api.dashboard=true`; Traefik then serves the dashboard on no entry point, so
`/dashboard/` and `/api/overview` both return Traefik's own 404 body. Set
`api.insecure: true` to bind the API to this entry point:

```bash
helm template t traefik/traefik --version 41.4.0 -n traefik-private -f values.yaml \
  --set api.insecure=true | grep -- '--api'
```

Expected output: `--api.dashboard=true` and `--api.insecure=true`.

> **Warning**: `api.insecure` serves the API and dashboard **without
> authentication**. Keep it off in shared clusters — the Service does not expose
> 8080, so port-forward is the safe access path when you do enable it.

---

## Values Reference

| Parameter | Description | Value here |
| --------- | ----------- | ---------- |
| `deployment.replicas` | Number of Traefik pods | `3` |
| `ingressClass.enabled` | Create an IngressClass | `true` |
| `ingressClass.isDefaultClass` | Do **not** make it the cluster default — `nginx` stays default | `false` |
| `ingressClass.name` | IngressClass object name | `traefik-private` |
| `ports.web.nodePort` | NodePort for HTTP (`:8000`) | `32080` |
| `ports.websecure.nodePort` | NodePort for HTTPS (`:8443`) | `32443` |
| `service.spec.type` | Service type | `NodePort` |
| `providers.kubernetesIngress.enabled` | Plain Ingress provider — off, the NGINX provider owns Ingress objects | `false` |
| `providers.kubernetesIngressNGINX.enabled` | NGINX-compatible Ingress provider | `true` |
| `providers.kubernetesIngressNGINX.ingressClass` | Ingress class name handled by this controller | `traefik-private` |
| `providers.kubernetesIngressNGINX.ingressClassByName` | Match the class by name, not only by controller value | `true` |
| `providers.kubernetesIngressNGINX.publishService.enabled` | Write the front-end Service into Ingress status — off for NodePort | `false` |
| `providers.kubernetesIngressNGINX.watchIngressWithoutClass` | Ignore Ingresses with no class | `false` |

Not set here, worth knowing:

| Parameter | Chart default | Effect here |
| --------- | ------------- | ----------- |
| `providers.kubernetesCRD.enabled` | `true` | `IngressRoute`/`Middleware` CRDs still work alongside the NGINX provider |
| `providers.kubernetesIngressNGINX.controllerClass` | `k8s.io/ingress-nginx` | Left untouched; `ingressClassByName: true` is what makes `traefik-private` match |
| `ports.traefik.expose.default` | `false` | Dashboard/`/ping` stay cluster-internal |
| `ingressClass` on rendered class | `traefik.io/ingress-controller` | Fixed controller for the class |
| `affinity` | `{}` | No anti-affinity — 3 replicas can land on one node |
| `podDisruptionBudget.enabled` | `false` | No PDB |

---

## Using the Ingress Class

Every app that should be served by this Traefik must name the class explicitly —
with `isDefaultClass: false` and `watchIngressWithoutClass: false`, this release
only handles Ingresses tagged `traefik-private`.

```yaml
spec:
  ingressClassName: traefik-private
```

The shared `nginx` class in this repo is unaffected; the two controllers coexist
because each only handles its own class.

`publishService.enabled: false` means `kubectl describe ingress` shows no
`Address`. That is expected on a NodePort front end — point clients (and DNS) at
`<NODE_IP>:32080` / `<NODE_IP>:32443`.

---

## Upgrade

```bash
helm upgrade traefik-private traefik/traefik \
  -n traefik-private --version <NEW_CHART_VERSION> \
  -f values.yaml
```

`crds/` is a one-time install directory — Helm will not update the `traefik.io`
CRDs. When the new chart version requires newer CRDs, pull the chart and apply
its CRDs by hand first:

```bash
helm pull traefik/traefik --version <NEW_CHART_VERSION> --untar --untardir /tmp
kubectl apply --server-side -f /tmp/traefik/crds/
```

Rollout is a rolling update of 3 pods; existing routes keep serving.

---

## Uninstall

```bash
helm uninstall traefik-private -n traefik-private
kubectl delete ns traefik-private
```

> **Warning**: CRDs and any `IngressRoute`/`Middleware` objects survive even
> namespace deletion. Removing the CRD types deletes all of those custom
> resources cluster-wide — confirm nothing else uses the `traefik.io` API group:
>
> ```bash
> kubectl get apiservice | grep traefik.io
> kubectl get crd | grep traefik.io
> ```

---

## Troubleshooting

- **`helm: command 'update' is not valid`** — the correct form is
  `helm upgrade -i traefik-private traefik/traefik -n traefik-private --version 41.4.0 -f values.yaml`.
- **404 but which 404?** — before anything else, tell Traefik's own 404 from the
  backend's. Traefik's is `Content-Length: 19` ("404 page not found\n") with
  `x-content-type-options: nosniff`; a backend 404 is `18` and carries the app's
  own headers, e.g. `access-control-allow-*`. **A backend 404 means routing
  works** — debug the app path, not Traefik.

```bash
curl -sS -D- -o /dev/null -H "Host: <APP_HOSTNAME>" http://<NODE_IP>:32080/
```

  To confirm a suspected backend 404, probe from inside the pod — the identical
  response proves Traefik is innocent:

```bash
kubectl -n <APP_NS> exec deploy/<APP> -- sh -c 'wget -qO- -S http://127.0.0.1:<PORT>/'
```

- **404 with no backend headers, `Content-Length: 19`** — the Ingress was never
  loaded by this controller, usually because it is not tagged with the class.
  Check:

```bash
kubectl get ingress -A --field-selector metadata.name=<INGRESS_NAME> \
  -o jsonpath='{.items[*].spec.ingressClassName}{"\n"}'
kubectl get events -n traefik-private --sort-by=.lastTimestamp | grep -i nginx
```

  Fix by setting `spec.ingressClassName: traefik-private`.
- **App Ingress is served by NGINX ingress instead of Traefik** — the Ingress
  says `ingressClassName: nginx` (the repo default). Both controllers are
  installed; the class string selects which one owns the route.
- **`kubectl describe ingress` shows no `Address`** — expected with
  `publishService.enabled: false`. Nothing is broken; the NodePort is the front
  end.
- **HTTPS on 32443 fails with a certificate error** — Traefik answers with
  `CN=TRAEFIK DEFAULT CERT` when no `spec.tls` secret matches the SNI. Read the
  served cert instead of guessing:

```bash
echo | openssl s_client -connect <NODE_IP>:32443 -servername <APP_HOSTNAME> 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

  Three causes, in the order to rule them out:

  1. Missing `spec.tls` on the Ingress, or the named Secret is absent from the
     Ingress's own namespace (it must be same-namespace, not cluster-wide):

```yaml
spec:
  tls:
    - secretName: <TLS_SECRET_NAME>
      hosts:
        - <APP_HOSTNAME>
```

  2. **The wildcard does not cover the host.** `*.tlnw.magnecomp.com` matches
     `one-level.tlnw.magnecomp.com` but *not*
     `api-app-ensaas.adv.tlnw.magnecomp.com` — a wildcard matches exactly one
     label. Hosts living two levels below the wildcard's parent need their own
     SAN or a second wildcard cert, otherwise Traefik falls back to its default
     cert even though the Secret exists and is referenced correctly.
  3. Malformed Secret — verify the pair actually matches:

```bash
kubectl -n <APP_NS> get secret <TLS_SECRET_NAME> -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/t.crt
kubectl -n <APP_NS> get secret <TLS_SECRET_NAME> -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/t.key
openssl x509 -noout -modulus -in /tmp/t.crt | openssl md5
openssl rsa  -noout -modulus -in /tmp/t.key | openssl md5
```

  Expected output: identical MD5s. **Use `openssl x509 -modulus`, not
  `openssl x509 -pubkey` — piping `x509 -pubkey` into `pkey -pubout` yields an
  empty digest (`e3b0c442...`) and looks like a mismatch when the Secret is fine.**

- **Connection refused on every `3xxxx` port, pods healthy and `Ready`** — almost
  always a hand-edited Service: `targetPort` no longer points at the entry-point
  ports (`web`/`8000`, `websecure`/`8443`), so kube-proxy DNATs to a closed port.
  Read it, do not eyeball `get svc`:

```bash
kubectl -n traefik-private get svc traefik-private \
  -o jsonpath='{range .spec.ports[*]}{.name}={.targetPort} nodePort={.nodePort}{"\n"}{end}'
```

  Expected output: `web=web nodePort=32080` / `websecure=websecure nodePort=32443`.
  The tell-tale of a Lens edit is rewritten port names (`http`/`https` instead of
  `web`/`websecure`) plus the annotation `k8slens-edit-resource-version`, and
  `managedFields` showing a manager other than `helm` touching the ports later
  than the Helm release time.

  To prove it from the node, read the DNAT rule kube-proxy actually programmed:

```bash
kubectl -n kube-system exec <KUBE-PROXY_POD_ON_NODE> -c kube-proxy -- \
  sh -c 'iptables-save -t nat | grep -E "comment .*traefik.*DNAT"'
```

  (The rule comment embeds the Service's port *name*, so grep the DNAT lines
  rather than a named chain.)

  Expected output: one line per pod, `DNAT --to-destination <POD_IP>:8000`. A
  `:80` there is the bug. On a healthy Service the comments read
  `traefik-private/traefik-private:web`; `:http`/`:https` comments mean someone
  renamed the ports too. Fix by re-deploying from `values.yaml`, never by
  re-editing the Service:

```bash
helm upgrade -i traefik-private traefik/traefik -n traefik-private --version 41.4.0 -f values.yaml
```

  **A `kubectl patch` or in-place edit of this Service works for one incident and
  guarantees the next; only the Helm release is authoritative.**

- **Time-out (no refusal) on `3xxxx` for some node IPs, refusal for others** —
  the datacenter firewall, not Kubernetes. Refusal means the packet reached
  kube-proxy and nothing was listening; silence means it was dropped on the way.
  On clusters where only worker nodes are opened for service ports, target the
  workers and treat control-plane `3xxxx` time-outs as expected. Compare per node:

```bash
for ip in <WORKER_IPS> <CONTROL_PLANE_IPS>; do
  printf "%-14s " "$ip"; timeout 4 bash -c "cat < /dev/null > /dev/tcp/$ip/32080" \
    2>/dev/null && echo OPEN || echo closed; done
```

- **`/dashboard/` and `/api/overview` return Traefik's own 404** — expected with
  these values; see [Verify](#verify). `--api.dashboard=true` alone binds the API
  to nothing.
- **Connection refused and `targetPort` is already correct** — a `nodePort`
  collision or the node firewall. Endpoints first, then the port owner:

```bash
kubectl -n traefik-private get endpoints traefik-private   # expect 3 pod IPs
kubectl get svc -A | grep -E "32080|32443"                 # another NodePort owns it
```
- **All 3 pods on one node** — no anti-affinity by default. Add
  `affinity` (the chart's `podAntiAffinity` example) or
  `topologySpreadConstraints` to `values.yaml` if that matters.
- **`helm upgrade` complains the `traefik.io` CRDs already exist and differ** —
  an earlier release installed them. Helm only owns `crds/` on the first
  install; take them over with `kubectl apply --server-side -f <crds dir>`.

---

## References

- [Traefik Helm chart repository](https://github.com/traefik/traefik-helm-chart)
- [Traefik Kubernetes Ingress NGINX provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/)
- [Traefik reference (VALUES)](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/VALUES.md)
