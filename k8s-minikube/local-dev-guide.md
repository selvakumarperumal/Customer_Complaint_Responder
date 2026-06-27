# Local Kubernetes Deployment Guide

Deploy the Customer Complaint Responder locally on **Minikube** using the standard Docker-in-Minikube build workflow.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed (`brew install minikube` / `sudo apt install minikube`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed

---

## Setup and Deploy

### 1. Start Minikube
Start your local Kubernetes cluster:
```bash
minikube start --driver=docker --memory=4096 --cpus=2
```

### 2. Point Docker to Minikube's Daemon
By pointing your shell's Docker client to Minikube's internal Docker daemon, any image you build will automatically be available inside Kubernetes:
```bash
eval $(minikube docker-env)
```
> **Note**: You must run this command in every new terminal window where you build Docker images. To undo this redirection in a shell, run `eval $(minikube docker-env --unset)`.

### 3. Build the Application Images
Build both images directly inside the Minikube environment:
```bash
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker
```

### 4. Create the Configuration Secret
Inject the environment variables from your local `.env` file into the namespace:
```bash
kubectl create secret generic ccr-secrets --from-env-file=.env -n ccr
```

### 5. Deploy Manifests
Deploy the namespace and application resources to Minikube:
```bash
kubectl apply -f k8s-minikube/
```

---

## Verification

Check the deployment status and verify that pods are running properly:

```bash
# Watch the pod status
kubectl get pods -n ccr -w

# Inspect service logs
kubectl logs -f deployment/poller -n ccr
kubectl logs -f deployment/worker -n ccr

# Port forward to access Redis locally (for debugging)
kubectl port-forward svc/redis 6379:6379 -n ccr
```

---

## Rebuilding After Code Changes

If you make modifications to your code and need to update the running pods:

```bash
# Make sure your terminal is pointed to minikube's docker environment
eval $(minikube docker-env)

# Rebuild the updated image(s)
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker

# Trigger a rolling update to restart the pods with the new images
kubectl rollout restart deployment/poller -n ccr
kubectl rollout restart deployment/worker -n ccr
```

---

## Troubleshooting

### 1. `ErrImageNeverPull`
* **Reason**: The Docker images were built on the host machine but are not available inside Minikube's Docker daemon.
* **Solution**: Ensure you ran `eval $(minikube docker-env)` before building. Alternatively, load the host-built images directly:
  ```bash
  minikube image load ccr-poller:latest
  minikube image load ccr-worker:latest
  ```

### 2. `CreateContainerConfigError`
* **Reason**: The Kubernetes secret `ccr-secrets` is missing or named incorrectly (e.g. `ccr-secret`).
* **Solution**: Re-create the secret inside the `ccr` namespace using the correct plural name:
  ```bash
  kubectl create secret generic ccr-secrets --from-env-file=.env -n ccr
  ```

---

## Manifest Files

All Kubernetes manifests are located in the `k8s-minikube/` directory:

| File | Resource Description |
|------|----------------------|
| `namespace.yaml` | Declares the `ccr` Namespace |
| `redis.yaml` | Deploys a single-replica Redis Instance + Service |
| `poller.yaml` | Deploys the Poller service (locked to 1 replica) |
| `worker.yaml` | Deploys the Worker service (scales to 2+ replicas) |

---

## Tear Down

Clean up resources and stop the cluster:
```bash
# Delete all resources and the ccr namespace
kubectl delete namespace ccr

# Stop Minikube
minikube stop

# Delete the minikube VM/container (fully cleans up cluster state)
minikube delete
```

