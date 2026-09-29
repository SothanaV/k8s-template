# kube-prometheus-stack

Monitoring and alerting stack (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics).

## Prerequisites

- Kubernetes cluster with the metrics-server add-on
- A storage class for Prometheus/Alertmanager PVCs (set `prometheus(prometheus).storage.storageClassName` in `values.yaml`)

## Installation

### 1. Add the Helm repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 2. Search for available versions

```bash
helm search repo prometheus-community/kube-prometheus-stack --versions | head -n 10
```

### 3. Install

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version <CHART_VERSION> \
  -f values.yaml
```

> **Note**: `values.yaml` does not exist yet in this directory — start from `default-values.yaml` (upstream defaults) and keep only the overrides you need.

## Upgrade

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version <CHART_VERSION> \
  -f values.yaml
```

## Uninstall

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete pvc --all -n monitoring
```

## Default Values

`default-values.yaml` is the full upstream default set (`helm show values prometheus-community/kube-prometheus-stack > default-values.yaml`), including:

- **Prometheus**: retention, storage, scraping intervals, additional scrape configs
- **Grafana**: admin access, datasources, dashboards, ingress
- **Alertmanager**: receivers, ingress
- **Exporters**: node-exporter, kube-state-metrics, windows-exporter
- **Components**: enable/disable individual sub-charts

## References

- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
