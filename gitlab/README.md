helm repo add gitlab https://charts.gitlab.io/
helm repo update

kubectl create namespace  gitlab

kubectl create secret generic gitlab-postgresql-password -n gitlab \
    --from-literal=postgresql-password="YOUR_SECURE_DB_PASSWORD"

kubectl create secret generic gitlab-redis-secret -n gitlab\
    --from-literal=redis-password="YOUR_SECURE_REDIS_PASSWORD"


helm upgrade --install gitlab gitlab/gitlab -n gitlab -f values.yaml

kubectl get secret <name>-gitlab-initial-root-password -ojsonpath='{.data.password}' | base64 --decode ; echo
