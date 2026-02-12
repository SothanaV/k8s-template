# n8n

- edit `values.yaml`

- install
```
helm install n8n oci://8gears.container-registry.com/library/n8n \
--namespace n8n --create-namespace \
--version 1.0.0 \
-f values.yaml