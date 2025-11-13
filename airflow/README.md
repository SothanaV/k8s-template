# Airflow
- require 
  - airflow image

0. create namespace
```
kubectl create namespace airflow
```
1. create gitlab secret
    - edit `secret-gitlab.yml`
    - apply secret
    ```
    kubectl apply -f secret-gitlab.yml
    ```

1. add helm airflow repo
```
helm repo add apache-airflow https://airflow.apache.org
helm repo update
```

2. search chech helm and airflow version
```
helm search repo apache-airflow/airflow --versions
```
```
NAME                    CHART VERSION   APP VERSION     DESCRIPTION                                       
apache-airflow/airflow  1.18.0          3.0.2           The official Helm chart to deploy Apache Airflo...
apache-airflow/airflow  1.17.0          3.0.2           The official Helm chart to deploy Apache Airflo...
apache-airflow/airflow  1.16.0          2.10.5          The official Helm chart to deploy Apache Airflo...
apache-airflow/airflow  1.15.0          2.9.3           The official Helm chart to deploy Apache Airflo...
```

APP VERSION must be align docker image 

3. edit `airflow-values.yml`

4. install

    - first install
    ```
    helm install airflow apache-airflow/airflow --namespace airflow --version 1.18.0 -f airflow-values.yml
    ```

    - update
    ```
    helm upgrade airflow apache-airflow/airflow --namespace airflow --version 1.18.0 -f values.yml
    ```

    - uninstall
    ```
    helm uninstall airflow -n airflow
    # delete pv
    kubectl delete pvc --all -n airflow
    ```

### If have permission problem
add webserver and scheduler deployment
```yml
initContainers:
  - name: fix-log-permissions
    image: busybox
    command: ["sh", "-c", "chown -R 50000:1001 /opt/airflow/logs"]
    volumeMounts:
      - name: logs
        mountPath: /opt/airflow/logs
    securityContext:
      runAsUser: 0 # run as root to change ownership
```