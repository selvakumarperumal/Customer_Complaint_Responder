# Customer Complaint Responder

A FastAPI backend that classifies customer complaints and generates professional responses using LangGraph and Google Gemini. Deployed on Amazon EKS with secrets injected from AWS Secrets Manager via External Secrets Operator (ESO).

---

## Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Local Development](#local-development)
- [Running with Docker](#running-with-docker)
- [Production Deployment](#production-deployment)
  - [1 — Provision AWS Infrastructure](#1--provision-aws-infrastructure)
  - [2 — Build and Push the Docker Image](#2--build-and-push-the-docker-image)
  - [3 — Deploy to EKS with Helm](#3--deploy-to-eks-with-helm)
- [API Reference](#api-reference)
- [Secret Rotation](#secret-rotation)

---

## Architecture

```
User
 │
 ▼
POST /api/v1/complaints
 │
 ▼
FastAPI (backend/)
 │
 ▼
LangGraph StateGraph
 │
 ▼
Google Gemini (via GOOGLE_API_KEY)
 │
 ▼
ComplaintResponse { complaint_type, response }
```

**Secret flow in production (no secrets in code or Helm values):**

```
terraform apply -var google_api_key=...
       │
       ▼  stores {"GOOGLE_API_KEY": "..."} as JSON
AWS Secrets Manager  "ccr-dev/google-api-key"
       │
       ▼  External Secrets Operator (IRSA auth)
Kubernetes Secret  "<release>-api-key"
       │
       ▼  mounted as env var
Pod  GOOGLE_API_KEY=...
```

---

## Repository Structure

```
.
├── backend/                  # FastAPI application
│   ├── app/
│   │   ├── api/routes/       # POST /complaints endpoint
│   │   ├── core/config.py    # Settings (reads GOOGLE_API_KEY from env)
│   │   ├── schemas/          # Request / response models
│   │   └── services/agent/   # LangGraph workflow + Gemini LLM
│   ├── Dockerfile
│   ├── main.py               # Uvicorn entrypoint
│   └── pyproject.toml
├── infra/                    # Terraform — AWS infra (VPC, EKS, ECR, Secrets Manager)
│   ├── modules/
│   │   ├── vpc/
│   │   ├── iam/
│   │   ├── eks/
│   │   ├── ecr/
│   │   └── secret_manager/   # Secrets Manager secret + IRSA role for the backend SA
│   ├── environments/
│   │   ├── dev.tfvars
│   │   └── prod.tfvars
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── helm/                     # Helm chart for the backend
    ├── templates/
    │   ├── deployment.yaml
    │   ├── serviceaccount.yaml   # IRSA annotation set at deploy time
    │   ├── secretstore.yaml      # ESO: how to connect to AWS
    │   ├── externalsecret.yaml   # ESO: which secret to fetch → creates K8s Secret
    │   └── ...
    └── values.yaml
```

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Python | 3.14 | [python.org](https://python.org) |
| uv | latest | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Docker | 24+ | [docker.com](https://docs.docker.com/get-docker/) |
| Terraform | 1.15+ | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| AWS CLI | v2 | `aws configure` with credentials that can create EKS/VPC/IAM |
| kubectl | 1.32+ | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | 3.14+ | `brew install helm` or [helm.sh](https://helm.sh/docs/intro/install/) |

---

## Local Development

```bash
# Clone and enter the backend directory
cd backend

# Install dependencies with uv
uv sync

# Create a .env file with your Gemini API key
echo "GOOGLE_API_KEY=AIza..." > .env
# or use the alias the app also accepts:
echo "GEMINI_API_KEY=AIza..." > .env

# Run the dev server (hot-reload enabled)
uv run python main.py
```

The API is available at **http://localhost:8000**  
Interactive docs: **http://localhost:8000/docs**

---

## Running with Docker

```bash
# Build the image
docker build -t ccr-backend ./backend

# Run with the API key injected as an env var
docker run -p 8000:8000 \
  -e GOOGLE_API_KEY=AIza... \
  ccr-backend
```

---

## Production Deployment

### 1 — Provision AWS Infrastructure

Terraform creates the VPC, EKS cluster, ECR repository, Secrets Manager secret, and the IRSA role that lets the backend pod read that secret.

```bash
cd infra

# Initialise providers and modules
terraform init

# Review what will be created (dev environment)
export TF_VAR_google_api_key="AIza..."        # never hard-code this
terraform plan -var-file=environments/dev.tfvars

# Apply
terraform apply -var-file=environments/dev.tfvars
```

> **Note:** The `google_api_key` is only needed during `terraform apply`. After that it lives in Secrets Manager — you never pass it to Helm or the pod directly.

Capture the outputs you'll need for the next steps:

```bash
export ECR_URL=$(terraform output -raw ecr_repository_url)
export IRSA_ARN=$(terraform output -raw backend_irsa_role_arn)
export CLUSTER=$(terraform output -raw cluster_name)
export AWS_REGION=$(terraform output -raw aws_region)

# Update your local kubeconfig
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
```

---

### 2 — Build and Push the Docker Image

```bash
# Authenticate Docker with ECR
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URL"

# Build and tag
docker build -t "$ECR_URL:v1.0.0" ./backend

# Push
docker push "$ECR_URL:v1.0.0"
```

---

### 3 — Deploy to EKS with Helm

#### Install External Secrets Operator (once per cluster)

ESO is a cluster-level dependency — install it before the app chart.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install eso external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --wait
```

#### Install the app chart

```bash
helm upgrade --install ccr ./helm \
  --namespace default \
  --set clusterName="$CLUSTER" \
  --set awsRegion="$AWS_REGION" \
  --set image.repository="$ECR_URL" \
  --set image.tag="v1.0.0" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$IRSA_ARN" \
  --wait
```

#### Verify the deployment

```bash
# ESO should sync the secret within seconds — look for READY=True
kubectl get externalsecret -n default

# Confirm the K8s Secret was created by ESO
kubectl get secret ccr-customer-complaint-responder-api-key -n default

# Check the pod is running
kubectl get pods -n default
kubectl logs -l app.kubernetes.io/name=customer-complaint-responder -n default
```

---

## API Reference

### `POST /api/v1/complaints`

Classify a complaint and generate a response.

**Request body:**
```json
{
  "complaint": "My order arrived damaged and customer service ignored my emails.",
  "thread_id": "optional-conversation-id"
}
```

**Response:**
```json
{
  "complaint": "My order arrived damaged...",
  "complaint_type": "Damaged Goods",
  "response": "We sincerely apologise for the inconvenience..."
}
```

### `GET /health`

Returns `{"status": "ok"}` — used by Kubernetes liveness and readiness probes.

---

## Secret Rotation

To rotate the Gemini API key with zero downtime:

```bash
# 1. Update the secret in Secrets Manager via Terraform
export TF_VAR_google_api_key="AIza...new-key..."
terraform apply -var-file=environments/dev.tfvars

# 2. ESO automatically syncs the new value within 1 hour.
#    To force an immediate sync:
kubectl annotate externalsecret ccr-customer-complaint-responder-api-key \
  force-sync=$(date +%s) --overwrite -n default

# 3. Restart the pod to pick up the new env var
kubectl rollout restart deployment/ccr-customer-complaint-responder -n default
```