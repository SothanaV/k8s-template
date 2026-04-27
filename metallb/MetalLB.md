# MetalLB

MetalLB is a load-balancer implementation for bare-metal Kubernetes clusters. It provides a network load balancer using standard routing protocols so that `LoadBalancer`-type services work outside of cloud environments.

## Prerequisites

- Kubernetes cluster (bare-metal or VM-based)
- Helm 3.x
- `kubectl` configured to target your cluster
- A range of unused IP addresses on your local network

## Installation

Add the Helm repository and install MetalLB into its own namespace:

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace
```

Verify the pods are running:

```bash
kubectl get pods -n metallb-system
```

## Configuration

The [metallb-config.yaml](metallb-config.yaml) defines two resources:

### IPAddressPool

Declares the pool of IP addresses MetalLB can assign to `LoadBalancer` services.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.16.2.21-10.16.2.24   # adjust to your network's available IP range
```

### L2Advertisement

Tells MetalLB to advertise the pool using Layer 2 (ARP/NDP) mode.

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
```

## Apply Configuration

Edit the IP range in `metallb-config.yaml` to match your network, then apply:

```bash
kubectl apply -f metallb-config.yaml
```

Verify the pool was created:

```bash
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

## Usage

Once configured, any service of type `LoadBalancer` will automatically receive an external IP from the pool:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
```

Check the assigned IP:

```bash
kubectl get svc my-service
```
