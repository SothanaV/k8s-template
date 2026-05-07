# S3 Manager

src: https://github.com/cloudlena/s3manager

## Helm Repository Setup

```bash
helm repo add sergeyshevch https://sergeyshevch.github.io/charts
helm repo update
```

## Search Available Versions

```bash
helm search repo sergeyshevch/s3manager --versions
```

## Configuration

Edit `values.yaml` with your settings:

```yaml
image:
  repository: cloudlena/s3manager
  tag: "latest"

ingress:
  hosts:
    - host: wn-a-prd-ai-k8s.tlnw.magnecomp.com
      paths:
        - path: /s3-manager/mc(/|$)(.*)
          pathType: ImplementationSpecific
          port: 80

configMap:
  data:
    ENDPOINT: "tlnw-prd-offqu2.tlnw.magnecomp.com:9000"
    ACCESS_KEY_ID: "<YOUR_ACCESS_KEY_ID>"
    SECRET_ACCESS_KEY: "<YOUR_SECRET_ACCESS_KEY>"
    USE_SSL: "true"
    ROOT_URL: "/s3-manager/mc"
```

> **Note**: Replace `<YOUR_ACCESS_KEY_ID>` and `<YOUR_SECRET_ACCESS_KEY>` with your actual S3 credentials.

## Installation

```bash
helm install s3manager sergeyshevch/s3manager --namespace s3-manager --create-namespace --version 0.1.0 -f values.yaml
```

## Uninstallation

```bash
helm uninstall s3manager -n s3-manager
```

## Authentication (Optional)

### 1. Create htpasswd

```bash
# -c creates a new file; 'auth' is the filename; 'admin' is the username
htpasswd -c auth system_admin
```

### 2. Create secret

```bash
kubectl create secret generic basic-auth --from-file=auth -n s3-manager
```

### 3. Update ingress annotations

```yaml
ingress:
  annotations:
    # Enable basic authentication
    nginx.ingress.kubernetes.io/auth-type: basic
    # Reference the secret created in Step 2
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    # Text displayed in the browser login prompt
    nginx.ingress.kubernetes.io/auth-realm: 'Authentication Required - Admin Only'