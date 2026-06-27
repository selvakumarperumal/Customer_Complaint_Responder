# Local Kubernetes Deployment Guide

Deploy the Customer Complaint Responder on **Minikube** or **Docker Desktop Kubernetes**
without pushing images to any remote registry.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running
- [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed (`brew install minikube` / `sudo apt install minikube`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed

---

## Option A: Minikube (Recommended)

### 1. Start Minikube

```bash
minikube start --driver=docker --memory=4096 --cpus=2
```

### 2. Build Images Directly Inside Minikube's Docker

This is the key trick — Minikube has its own Docker daemon. By pointing
your shell's Docker client to Minikube's daemon, images you build are
immediately available to Kubernetes without any push/pull:

```bash
# Point your shell to Minikube's Docker daemon
eval $(minikube docker-env)

# Build both images (they now exist inside Minikube)
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker

# Verify they're there
docker images | grep ccr
```

> **Important:** Every new terminal needs `eval $(minikube docker-env)` again.
> To undo it: `eval $(minikube docker-env --unset)`

### 3. Deploy

```bash
# Create namespace
kubectl create namespace ccr

# Create the secret from your .env file
kubectl create secret generic ccr-secrets \
  --from-env-file=.env \
  -n ccr

# Deploy all manifests
kubectl apply -f k8s/ -n ccr
```

### 4. Verify

```bash
# Check all pods are running
kubectl get pods -n ccr -w

# Check logs
kubectl logs -f deployment/poller -n ccr
kubectl logs -f deployment/worker -n ccr

# Access Redis (for debugging)
kubectl port-forward svc/redis 6379:6379 -n ccr
```

### 5. Tear Down

```bash
kubectl delete namespace ccr
minikube stop    # pause (preserves state)
minikube delete  # full cleanup
```

---

## Option B: Docker Desktop Kubernetes

Docker Desktop's built-in Kubernetes shares the same Docker daemon,
so images you build locally are already available:

```bash
# Enable Kubernetes in Docker Desktop Settings → Kubernetes → Enable

# Build images (they're automatically available to K8s)
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker

# Deploy
kubectl create namespace ccr
kubectl create secret generic ccr-secrets --from-env-file=.env -n ccr
kubectl apply -f k8s/ -n ccr
```

---

## Option C: Minikube with `minikube image load`

If you prefer building with your host Docker and loading into Minikube:

```bash
# Build on your host
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker

# Load into Minikube (copies the image tarball)
minikube image load ccr-poller:latest
minikube image load ccr-worker:latest

# Verify
minikube image ls | grep ccr
```

> **Note:** `minikube image load` is slower than Option A because it
> exports the image as a tarball and imports it. Use Option A for
> faster iteration during development.

---

## Rebuilding After Code Changes

```bash
# If using Option A (recommended):
eval $(minikube docker-env)
docker build -t ccr-poller:latest ./apps/poller
docker build -t ccr-worker:latest ./apps/worker

# Restart deployments to pick up new images
kubectl rollout restart deployment/poller -n ccr
kubectl rollout restart deployment/worker -n ccr
```

---

## Manifest Files

All Kubernetes manifests are in the `k8s/` directory:

| File | What it creates |
|------|----------------|
| `redis.yaml` | Redis Deployment + Service |
| `poller.yaml` | Poller Deployment (1 replica only) |
| `worker.yaml` | Worker Deployment (2 replicas, scalable) |
