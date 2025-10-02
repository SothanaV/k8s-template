# CloudBever via helm
- add helm repo
```
helm repo add avisto https://avistotelecom.github.io/charts/
helm repo update
```

- list helm version
```
helm search repo avisto/cloudbeaver --versions
```
```
NAME                    CHART VERSION   APP VERSION     DESCRIPTION           
avisto/cloudbeaver      1.0.6           25.2.1          Cloud Database Manager
avisto/cloudbeaver      1.0.5           25.2.0          Cloud Database Manager
avisto/cloudbeaver      1.0.4           25.1.5          Cloud Database Manager
avisto/cloudbeaver      1.0.3           25.1.4          Cloud Database Manager
avisto/cloudbeaver      1.0.2           25.1.3          Cloud Database Manager
avisto/cloudbeaver      1.0.1           25.1.3          Cloud Database Manager
avisto/cloudbeaver      1.0.0           25.1.2          Cloud Database Manager
```

- install
```
helm install cloudbeaver avisto/cloudbeaver --namespace cloudbever --create-namespace --version 1.0.6 -f values.yml
```

- uninstall 
```
helm uninstall cloudbeaver --namespace cloudbever
kubectl delete pvc --all -n cloudbever
```