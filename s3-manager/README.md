# S3 Manager
src : https://github.com/cloudlena/s3manager
- add helm repo
```
helm repo add sergeyshevch https://sergeyshevch.github.io/charts
helm repo update
```

- list app versions
```
helm search repo sergeyshevch --versions 
```
example
```
NAME                                    CHART VERSION   APP VERSION     DESCRIPTION                                       
sergeyshevch/multi-gatekeeper           1.2.0           5.0.0           Chart for simplify deploing multiple keycloak-g...
sergeyshevch/s3manager                  0.1.0           0.2.0           Chart for s3manager - web GUI for s3              
sergeyshevch/statuspage-exporter        1.3.0                           Statuspage exporter exports metrics from given ...
sergeyshevch/statuspage-exporter        1.2.0                           Statuspage exporter exports metrics from given ...
sergeyshevch/topologyspread-webhook     0.1.0           v0.1.0          Mutation webhook for replacinf podAntiAffinity ...
```

- edit `values.yaml`

- install
```
helm install s3manager sergeyshevch/s3manager --namespace s3-manager --create-namespace --version 0.1.0 -f values.yaml 
```

- uninstall
```
helm uninstall s3manager -n s3-manager
```