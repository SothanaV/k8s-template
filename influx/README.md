# InfluxDB (subpath proxy)

Sidecar nginx proxy that serves the InfluxDB UI under a subpath
(`/influxdb/`), because the InfluxDB 2 UI does not support a base path
natively.

## Files

| File | Purpose |
|------|---------|
| `configmaps.yaml` | `influxdb-nginx-config` ConfigMap with `nginx.conf` |

The nginx server listens on `8080`, strips the `/influxdb` prefix, and
proxies to the local InfluxDB on `8086`.

## Installation

1. Deploy InfluxDB as usual (e.g. Bitnami chart or the official image) with
   the nginx container as a sidecar:

   ```yaml
   containers:
     - name: influxdb
       image: influxdb:2
       ports:
         - containerPort: 8086
     - name: nginx-proxy
       image: nginx:stable-alpine
       ports:
         - containerPort: 8080
       volumeMounts:
         - name: nginx-config
           mountPath: /etc/nginx/nginx.conf
           subPath: nginx.conf
   volumes:
     - name: nginx-config
       configMap:
         name: influxdb-nginx-config
   ```

2. Apply the ConfigMap:

   ```bash
   kubectl apply -f configmaps.yaml -n influx
   ```

3. Point your ingress at the proxy port (`8080`) with path `/influxdb`.

## Notes

- If the InfluxDB UI is unreachable after install, finish its setup wizard
  first — the proxy only rewrites paths, it does not initialize the instance.
- To change the exposed path, edit both the `location`/`rewrite` in
  `nginx.conf` and the ingress path.
