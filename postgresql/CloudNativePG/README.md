# 1. add + refresh the repo (already in your README.md)
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

# 2. dump the default values.yaml to a file
helm show values cnpg/cloudnative-pg > values.yaml

    # pin the chart version you actually deploy — defaults differ between versions
    helm search repo cnpg/cloudnative-pg --versions
    helm show values cnpg/cloudnative-pg --version 0.29.2 > values.yaml
    Related, once you need more than the values file:
    # whole chart source (templates + values + CRDs) for reading or vendoring
    helm pull cnpg/cloudnative-pg --version 0.29.2 --untar --untardir ./charts

    # only the CRDs (the Cluster CRD is where most schema questions live)
    helm show crds cnpg/cloudnative-pg --version 0.29.2

    # values of an ALREADY-installed release
    helm get values <release> -n <ns>            # only what you overrode
    helm get values <release> -n <ns> --all      # including computed defaults

# 3 install
helm upgrade --install cnpg --namespace cnpg-system --create-namespace cnpg/cloudnative-pg

# 4 create pg cluster
```
kubectl apply -f pg-cluster.yaml
```

    # Uninstall
    1. list cluster
    ```
    kubectl get clusters.postgresql.cnpg.io -A
    ```

    2. delete
    ```
    kubectl delete cluster <cluster-name> -n <namespace>
    ```

## uninstall cnpg
```
helm uninstall cnpg -n cnpg-system
```

```
kubectl delete namespace cnpg-system
```