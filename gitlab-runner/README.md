# Gitlab runner
1. add gitlab runner
```
helm repo add gitlab https://charts.gitlab.io
```
2. edit values.yml
```
serviceAccount:
  create: true # firsttime true next false
  name: gitlabrunner-service-account
```
3. 
```
helm install --namespace <NAMESPACE> gitlab-runner -f values.yml gitlab/gitlab-runner
```