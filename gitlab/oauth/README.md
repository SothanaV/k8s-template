# OAuth Configuration

1. Edit `provider.yaml` with your OAuth credentials

2. Apply the secret
```
kubectl create secret generic gitlab-oauth-moma \
  --from-file=provider=provider.yaml \
  -n gitlab
```

3. Update Helm values and upgrade
```
helm upgrade gitlab gitlab/gitlab \
  -n gitlab \
  -f values.yaml \
  --version 9.11.1
```

## provider.yaml Template

```yaml
name: "oauth2_generic"
label: "YOUR_PROVIDER_LABEL"
app_id: "YOUR_APP_ID_HERE"
app_secret: "YOUR_APP_SECRET_HERE"
args:
  client_options:
    site: "https://your-oauth-server.example.com"
    user_infos_url: "/api/v1/account/me"
    authorize_url: "/o/authorize/"
    token_url: "/o/token/"
    connection_opts:
      ssl:
        verify: false
  user_response_structure:
    attributes:
      nickname: "username"
      name: "username"
      email: "email"
      admin: "is_superuser"
  strategy_class: "OmniAuth::Strategies::OAuth2Generic"
```

> **Warning**: Never commit `provider.yaml` to version control. It contains sensitive OAuth credentials.