# n8n Deployment with Helm

This document provides instructions for deploying n8n on a Kubernetes cluster using the `community-charts/n8n` Helm chart.

This setup uses a custom `values.yaml` file to:
- Deploy n8n with a specific version (`2.8.1`).
- Enable an in-cluster PostgreSQL database for persistence instead of the default SQLite.
- Configure persistence for workflow data.
- Expose n8n via an Ingress.

## Prerequisites

- Helm 3 installed.
- A running Kubernetes cluster.
- An Ingress controller (e.g., NGINX) installed in the cluster.
- A valid TLS secret for your domain (e.g., `star-xyz-cert` in `values.yaml`).

## Configuration

Before deploying, you **must** edit `values.yaml` to provide your environment-specific details.

### 1. Generate Encryption Key

n8n requires an encryption key to secure sensitive credential data.

1.  Generate a random 32-byte hex string:
    ```bash
    openssl rand -hex 32
    ```

2.  Open `values.yaml` and paste the generated key as the value for `encryptionKey`:
    ```yaml
    # values.yaml
    ...
    # 2. Security (PASTE YOUR GENERATED KEY BELOW)
    encryptionKey: "PASTE_YOUR_GENERATED_KEY_HERE" # <-- REPLACE THIS
    ...
    ```

### 2. Set Database Password

Update the password for the internal PostgreSQL database.

In `values.yaml`, change the placeholder password:
```yaml
# values.yaml
...
# 4. Enable the internal Postgres database
postgresql:
  enabled: true
  auth:
    username: n8n
    password: "secure_db_password" # <-- CHANGE THIS to a strong password
    database: n8n
...
```

### 3. Configure Ingress

Update the Ingress to use your domain and TLS secret.

In `values.yaml`, modify the `hosts` and `tls` sections:
```yaml
# values.yaml
...
# 6. Ingress (Expose to the internet)
ingress:
  enabled: true
  className: nginx # Change if using a different Ingress controller
  hosts:
    - host: n8n.your-domain.com # <-- CHANGE THIS
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls:
    - secretName: your-tls-secret-name # <-- CHANGE THIS
      hosts:
        - n8n.your-domain.com # <-- CHANGE THIS
...
```

## Installation

1.  Add the community Helm repository:
    ```bash
    helm repo add community-charts https://community-charts.github.io/helm-charts
    helm repo update
    ```

2.  Install the n8n chart with your custom values:
    ```bash
    helm install n8n community-charts/n8n \
      --namespace n8n \
      --create-namespace \
      -f values.yaml
    ```

## Uninstallation

To uninstall the `n8n` release from your cluster:
```bash
helm uninstall n8n --namespace n8n
```

> **Note:** This command does not delete the PersistentVolumeClaims (PVCs) created for n8n and its database. To permanently delete all data, you must manually delete the PVCs after running the uninstall command.

### Delete PersistentVolumeClaims (PVCs)
```bash
kubectl delete pvc --all --namespace n8n
```