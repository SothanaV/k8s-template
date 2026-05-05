# Open WebUI - Kubernetes Helm Deployment

> **⚠️ WARNING:** This repository contains **example configurations only**. Replace all placeholder values (`<your-...>`) with your actual credentials before deploying. Never commit real secrets to version control.

This repository contains Helm values for deploying [Open WebUI](https://github.com/open-webui/open-webui) on Kubernetes.

## Quick Setup Options

| Option | Description | Use Case |
|--------|-------------|----------|
| **Anonymous Access** | No authentication required | Development/testing environments |
| **OAuth/OIDC** | Enterprise single sign-on | Production environments |
| **Email/Password** | Built-in user registration | General use |

## Overview

Open WebUI is a user-friendly web interface for chat models, including Ollama and OpenAI-compatible APIs. This deployment configures the official Open WebUI Helm chart with custom settings for production use.

## Prerequisites

- Kubernetes cluster
- Helm 3+
- NGINX Ingress Controller
- Persistent Storage class (update in `values.yaml`)
- PostgreSQL database (or set `databaseUrl` to your connection string)

## Authentication Options

Choose **one** of the following authentication methods:

### Option 1: Anonymous Access (No Authentication)

For development or testing environments where security is not a concern:

```yaml
# values.yaml - Add these environment variables
extraEnvVars:
  - name: ENABLE_LOGIN_FORM
    value: 'false'
  - name: ENABLE_SIGNUP
    value: 'false'
  - name: WEBUI_AUTH
    value: 'false'
```

> **Warning:** Do NOT use anonymous access in production. Anyone can access the application without credentials.

### Option 2: OAuth/OIDC (Recommended for Production)

For enterprise environments with a centralized identity provider (Keycloak, Okta, Azure AD, etc.):

See the [OAuth Configuration Example](#oauth-configuration-example) section below.

### Option 3: Email/Password Authentication

For standard user registration and login:

```yaml
# values.yaml - Enable built-in authentication
extraEnvVars:
  - name: WEBUI_AUTH
    value: 'true'
  - name: ENABLE_SIGNUP
    value: 'true'
  - name: ENABLE_LOGIN_FORM
    value: 'true'
```

## Quick Start
### 0. Install postgresql

### 1. Add the Helm repository

```bash
helm repo add open-webui https://helm.openwebui.com/
helm repo update
```

### 2. Search for available versions

```bash
helm search repo open-webui/open-webui --versions
```

### 3. Install

```bash
helm install open-webui open-webui/open-webui \
  --version 14.2.0 \
  --namespace open-webui-dev \
  -f values.yaml
```

## Configuration

### Custom Values (`values.yaml`)

The `values.yaml` file contains production-specific overrides:

| Setting | Value | Description |
|---------|-------|-------------|
| `ollama.enabled` | `false` | Disable bundled Ollama |
| `pipelines.enabled` | `false` | Disable pipelines |
| `image.repository` | `ghcr.io/open-webui/open-webui` | Container image |
| `image.tag` | `0.9.2` | Open WebUI version |
| `ingress.enabled` | `true` | Enable NGINX Ingress |
| `ingress.class` | `nginx` | Ingress controller |
| `persistence.enabled` | `true` | Enable PVC |
| `persistence.storageClass` | `hpe-rwx` | Storage class |
| `persistence.size` | `10Gi` | PVC size |
| `persistence.accessMode` | `ReadWriteMany` | Multi-node access |
| `enableOpenaiApi` | `false` | Disable OpenAI API |

### NGINX Ingress Configuration

Special annotations are configured for proper operation:

```yaml
ingress:
  annotations:
    # Regex support for path rewriting
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2

    # Required for SSE streaming / WebSockets
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"

    # Rewrite static asset paths
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Accept-Encoding "";
      sub_filter 'href="/' 'href="/webui/';
      sub_filter 'src="/' 'src="/webui/';
      sub_filter '/_app/' '/webui/_app/';
      sub_filter '/api/' '/webui/api/';
      sub_filter_once off;
```

> **Note:** Update `ingress.host` to your actual domain name.

### Environment Variables

```yaml
extraEnvVars:
  - name: WEBUI_URL
    value: "https://your-domain.example.com/webui"
  - name: CORS_ALLOW_ORIGIN
    value: "https://your-domain.example.com"
```

### Default Values (`default-values.yaml`)

The `default-values.yaml` file contains the full set of configurable options from the upstream Helm chart, including:

- **External Tools**: Ollama, Pipelines, Tika, Terminals
- **WebSocket**: Redis configuration for real-time features
- **Image**: Repository, tag, pull policy
- **Service Account**: Creation and automation settings
- **Probes**: Liveness, readiness, startup health checks
- **Ingress**: NGINX, GKE, and generic ingress options
- **Route**: OpenShift Gateway routes
- **Persistence**: Local, S3, GCS, Azure storage backends
- **SSO**: Google, Microsoft, GitHub, OIDC OAuth
- **OpenAI API**: Key configuration and base URLs
- **Logging**: Granular log level control

## Uninstall

```bash
helm uninstall open-webui -n open-webui-dev
```

## Upgrading

```bash
helm upgrade open-webui open-webui/open-webui \
  --version 14.2.0 \
  --namespace open-webui-dev \
  -f values.yaml
```

## References

- [Open WebUI GitHub](https://github.com/open-webui/open-webui)
- [Open WebUI Documentation](https://docs.openwebui.com/)
- [Helm Chart Repository](https://helm.openwebui.com/)

## OAuth Configuration Example

For OAuth/OIDC authentication, configure the following environment variables. Replace all `<your-...>` placeholders with actual values from your identity provider.

```yaml
extraEnvVars:
  - name: WEBUI_AUTH
    value: 'true'
  - name: ENABLE_LOGIN_FORM
    value: 'false'
  - name: ENABLE_OAUTH_GROUP_CREATION
    value: 'true'
  - name: ENABLE_OAUTH_GROUP_MANAGEMENT
    value: 'true'
  - name: ENABLE_OAUTH_SIGNUP
    value: 'true'
  - name: ENABLE_SIGNUP
    value: 'false'
  - name: OAUTH_CLIENT_ID
    value: "<your-oauth-client-id>"
  - name: OAUTH_CLIENT_SECRET
    value: "<your-oauth-client-secret>"
  - name: OAUTH_GROUP_CLAIM
    value: roles
  - name: OAUTH_GROUP_DEFAULT_SHARE
    value: members
  - name: OAUTH_PROVIDER_NAME
    value: "<your-provider-name>"
  - name: OAUTH_SCOPES
    value: "openid profile email"
  - name: OAUTH_SUB_CLAIM
    value: email
  - name: OPENID_PROVIDER_URL
    value: "https://your-oauth-server.example.com/.well-known/openid-configuration"
```

### OAuth Setup Checklist

1. [ ] Register your application in your OAuth provider (Keycloak, Okta, Azure AD, etc.)
2. [ ] Configure the redirect URI: `https://your-domain.example.com/oauth/callback`
3. [ ] Copy `client_id` and `client_secret` from your provider
4. [ ] Update `OPENID_PROVIDER_URL` to your provider's discovery endpoint
5. [ ] Store credentials in Kubernetes Secrets (never in plain text)

### Using Kubernetes Secrets for OAuth Credentials

```yaml
# Create a secret first
kubectl create secret generic open-webui-oauth \
  --from-literal=OAUTH_CLIENT_ID="your-client-id" \
  --from-literal=OAUTH_CLIENT_SECRET="your-client-secret" \
  -n open-webui

# Then reference in values.yaml
extraEnvVarsSecret:
  - name: open-webui-oauth
```
