# Nginx Ingress install via Helm

- add helm repo
```
helm repo add nginx-stable https://helm.nginx.com/stable
helm repo update
```

- list app versions
```
helm search repo nginx-stable/nginx-ingress --versions
```

example
```
NAME                            CHART VERSION   APP VERSION     DESCRIPTION
nginx-stable/nginx-ingress      1.4.2           3.7.2           NGINX Ingress Controller
nginx-stable/nginx-ingress      1.4.1           3.7.1           NGINX Ingress Controller
nginx-stable/nginx-ingress      1.3.2           3.6.2           NGINX Ingress Controller
```

- edit `values.yaml`

- install
```
helm install nginx-ingress nginx-stable/nginx-ingress \
  --namespace default
```

- uninstall
```
helm uninstall nginx-ingress -n default
```