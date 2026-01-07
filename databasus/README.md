# Databasus
- edit values.yml
    - tag image : https://hub.docker.com/r/databasus/databasus/tags
- install
    ```
    helm install databasus oci://ghcr.io/databasus/charts/databasus \
    -n databasus --create-namespace \
    -f values.yml
    ```