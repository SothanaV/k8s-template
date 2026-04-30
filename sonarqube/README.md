# Sonarqube
- install postgresql first
- add helm repo
```
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update
```

- list app versions
```
helm search repo sonarqube/sonarqube --versions
```

example
```
NAME                    CHART VERSION   APP VERSION             DESCRIPTION
sonarqube/sonarqube     10.8.1+3453     26.4.0.121862           Code quality and security analysis platform
sonarqube/sonarqube     10.8.0+3432     26.3.0.121491           Code quality and security analysis platform
sonarqube/sonarqube     10.7.0+3598     25.12.0.109743          Code quality and security analysis platform
```

- edit `values.yml`

- install
```
helm install sonarqube sonarqube/sonarqube \
  --version 2026.2.1 \
  --namespace sonarqube \
  --create-namespace \
  --set monitoringPasscode=passcode \
  -f values.yml
```

- update
```
helm upgrade sonarqube sonarqube/sonarqube \
  --version 2026.2.1 \
  --namespace sonarqube \
  --set monitoringPasscode=passcode \
  -f values.yml
```

- uninstall
```
helm uninstall sonarqube -n sonarqube
# delete pvc
kubectl delete pvc --all -n sonarqube
```

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `image.tag` | `26.4.0.121862-community` | SonarQube image version |
| `replicaCount` | `1` | Number of replicas (must be 1) |
| `deploymentType` | `StatefulSet` | Deployment type |
| `service.type` | `ClusterIP` | Kubernetes service type |
| `service.externalPort` | `9000` | Exposed port |
| `ingress.enabled` | `true` | Enable ingress |
| `ingress.hosts[0].name` | `sonarqube.local.dfellow.com` | Ingress hostname |
| `persistence.storageClass` | `longhorn` | Storage class for PVC |
| `persistence.size` | `5Gi` | PVC size |
| `resources.limits.cpu` | `800m` | CPU limit |
| `resources.limits.memory` | `6144M` | Memory limit |
| `resources.requests.cpu` | `400m` | CPU request |
| `resources.requests.memory` | `2048M` | Memory request |
| `monitoringPasscode` | *(set at install)* | Passcode for monitoring endpoint |

## deploy on subpath
1. update env
```yml
containers:
  - name: sonarqube
    env:
      - name: SONAR_WEB_CONTEXT
        value: /sonarqube
    readinessProbe:
      exec:
        command:
        ...
         http://localhost:9000/sonarqube/api/system/status
```
2. update ingress
```yml
metadata:
  annotations:
     nginx.ingress.kubernetes.io/rewrite-target: /sonarqube/$2

spec:
  rules:
    - host: sonarqube.xxx.com
      http:
          paths:
            - path: /sonarqube(/|$)(.*)
              pathType: ImplementationSpecific