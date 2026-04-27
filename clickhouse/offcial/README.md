helm repo add altinity https://helm.altinity.com
helm repo update

helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace clickhouse --create-namespace


helm install ck-keeper altinity/clickhouse-keeper \
  --set image.repository=clickhouse/clickhouse-keeper \
  --set image.tag=25.8-alpine \
  --set replicaCount=3 \
  --set persistence.storageClass=hpe-rwo \
  --set persistence.size=20Gi \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=kubernetes.io/hostname" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values={lnw-prd-insw04,lnw-prd-insw05,lnw-prd-insw06,lnw-prd-insw07}"