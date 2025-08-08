# Gitlab runner
1. add gitlab runner
```
helm repo add gitlab https://charts.gitlab.io
```
2. edit values.yml
```
helm install --namespace <NAMESPACE> gitlab-runner -f values.yml gitlab/gitlab-runner
```