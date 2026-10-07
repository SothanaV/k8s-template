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

Expected output: the whoami body listing `Hostname` and headers. Remove the
test objects afterwards:

```bash
kubectl -n traefik-private delete deploy,svc,ingress whoami
```

Dashboard and `/ping` are on the `traefik` entry point (8080), which is
intentionally not exposed by the Service. Reach it locally:

```bash
kubectl -n traefik-private port-forward deploy/traefik-private 8080:8080
```

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
- **App Ingress returns 404 "404 page not found"** — Ingress is not tagged with
  the class, so the provider never loaded it. Check:

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
- **HTTPS on 32443 fails with a certificate error** — Traefik answers with its
  self-signed default certificate when no `spec.tls` secret matches the SNI.
  Attach the existing wildcard TLS Secret in the app's namespace:

```yaml
spec:
  tls:
    - secretName: <TLS_SECRET_NAME>
      hosts:
        - <APP_HOSTNAME>
```

- **Connection refused on 32080/32443** — a `nodePort` collision or the node
  firewall blocking the port. Endpoints first, then the port owner:

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
