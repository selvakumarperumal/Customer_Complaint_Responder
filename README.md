# Customer Complaint Responder

A FastAPI backend that classifies customer complaints and generates professional responses using LangGraph and Google Gemini. Deployed on Amazon EKS with secrets injected from AWS Secrets Manager via External Secrets Operator (ESO).

---

## Table of Contents

- [Architecture](#architecture)
- [How OIDC and IRSA work together](#how-oidc-and-irsa-work-together)
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

**Secret flow in production — the API key never touches Helm values or your shell:**

```
terraform apply -var google_api_key=AIza...
       │
       ▼  stores {"GOOGLE_API_KEY": "AIza..."} as JSON
AWS Secrets Manager  "ccr-dev/google-api-key"
       │
       ▼  External Secrets Operator reads it using the pod's IRSA credentials
Kubernetes Secret  "ccr-customer-complaint-responder-api-key"  (created by ESO)
       │
       ▼  Deployment mounts it as an environment variable
Pod  GOOGLE_API_KEY=AIza...
```

---

## How OIDC and IRSA work together

> **TL;DR — OIDC is the protocol. IRSA is the pattern that uses it. The IAM role is created by Terraform; the Kubernetes ServiceAccount is created by Helm. This split is intentional and correct.**

### The concepts

| Term | What it is |
|---|---|
| **OIDC provider** | A trust anchor registered in AWS IAM that says "I trust tokens issued by this EKS cluster" |
| **IRSA role** | An IAM role whose trust policy says "only allow this specific Kubernetes service account to assume me" |
| **ServiceAccount annotation** | `eks.amazonaws.com/role-arn: <role-arn>` — tells EKS which IRSA role to exchange tokens for |

### Who creates what, and why

```
Terraform  (AWS resources + platform K8s objects — infra/main.tf + infra/addons.tf)
  ├─ aws_iam_openid_connect_provider   ← OIDC provider
  ├─ aws_iam_role.backend_sa           ← IRSA role (trust policy scoped to the SA)
  ├─ aws_iam_role_policy_attachment    ← grants secretsmanager:GetSecretValue
  ├─ aws_iam_role_policy_attachment    ← grants ECR pull permissions
  └─ kubernetes_service_account_v1     ← SA pre-annotated with the IRSA role ARN
                                          (created AFTER EKS via depends_on)

Helm  (app workload objects — scripts/deploy.sh)
  ├─ Deployment
  ├─ Service
  ├─ ESO SecretStore + ExternalSecret
  └─ (references the pre-existing SA — does NOT create it)
```

**Why create the Kubernetes ServiceAccount in Terraform (using the `kubernetes` provider)?**

- **Single `terraform apply`** creates everything end-to-end. By the time you run `helm upgrade`, the SA already exists with the correct IRSA annotation — no flag needed.
- **No annotation to pass at deploy time** — `helm/values.yaml` has `serviceAccount.create: false`. Helm just references the SA by name. You can't accidentally forget or misspell the role ARN.
- **Clean lifecycle** — `terraform destroy` removes the SA alongside the IRSA role. `helm uninstall` removes the app workloads. No conflicts.
- **How chicken-and-egg is solved** — The `kubernetes` provider uses `exec { command = "aws" args = ["eks", "get-token", ...] }`. The token is fetched at *apply time*, not at init/plan time. Terraform's dependency graph ensures EKS is created first; only then does it connect to Kubernetes to create the SA.

### What happens at runtime (inside the pod)

```
1. EKS injects a short-lived OIDC token onto the pod via the SA volume
   (no passwords or long-lived credentials stored anywhere)

2. ESO (running in the cluster) calls STS:AssumeRoleWithWebIdentity
   using that token + the IRSA role ARN from the SA annotation

3. STS validates:
   "Is this token from our trusted OIDC provider?"       → yes
   "Is the subject claim system:serviceaccount:default:backend?"  → yes
   → returns temporary credentials (15 min TTL, auto-refreshed)

4. ESO uses those credentials to call secretsmanager:GetSecretValue
   → creates the Kubernetes Secret with GOOGLE_API_KEY
   → the pod reads it as a normal environment variable
```

### Why the ECR URL is NOT stored in Secrets Manager

The ECR URL (`123456789.dkr.ecr.ap-south-1.amazonaws.com/ccr-dev/backend`) is **not a secret** — it's just config derived from your AWS account ID and region. Storing it in Secrets Manager would be wrong (Secrets Manager is for sensitive credentials) and unnecessary. The deploy script reads it directly from `terraform output`.

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
├── infra/                    # Terraform — VPC, EKS, ECR, Secrets Manager, IRSA
│   ├── modules/
│   │   ├── vpc/
│   │   ├── iam/              # EKS cluster + node group roles
│   │   ├── eks/              # Cluster, node groups, OIDC provider
│   │   ├── ecr/              # Container registry + ECR pull IAM policy
│   │   └── secret_manager/   # Secrets Manager secret + IRSA role (created here)
│   ├── environments/
│   │   ├── dev.tfvars        # Dev config (no secrets — api key via TF_VAR_)
│   │   └── prod.tfvars
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── helm/                     # Helm chart for the backend
│   ├── templates/
│   │   ├── deployment.yaml
│   │   ├── serviceaccount.yaml   # IRSA annotation applied here at deploy time
│   │   ├── secretstore.yaml      # ESO: how to connect to AWS (uses IRSA auth)
│   │   ├── externalsecret.yaml   # ESO: which secret to fetch → creates K8s Secret
│   │   └── ...
│   └── values.yaml
└── scripts/
    ├── build-push.sh         # Build Docker image and push to ECR
    └── deploy.sh             # Deploy Helm chart (reads all values from terraform output)
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
cd backend

# Install dependencies
uv sync

# Create a .env file (the app also accepts GEMINI_API_KEY as an alias)
echo "GOOGLE_API_KEY=AIza..." > .env

# Start the dev server with hot-reload
uv run python main.py
```

API: **http://localhost:8000** — Docs: **http://localhost:8000/docs**

---

## Running with Docker

```bash
docker build -t ccr-backend ./backend

docker run -p 8000:8000 -e GOOGLE_API_KEY=AIza... ccr-backend
```

---

## Production Deployment

### 1 — Provision AWS Infrastructure

One `terraform apply` creates everything: VPC, EKS cluster, ECR repository, Secrets Manager secret, OIDC provider, and the IRSA role. Nothing needs to be set up manually afterward.

```bash
cd infra

terraform init

# The API key is the only secret — pass it via env var, never in tfvars files
export TF_VAR_google_api_key="AIza..."

terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

After `apply`, the API key is stored in Secrets Manager and the IRSA role exists. You never need to handle the key again.

---

### 2 — Build and Push the Docker Image

The script reads the ECR URL and region directly from `terraform output` — no copy-paste needed:

```bash
# Default tag is the git short SHA (e.g. a3f1c2d)
./scripts/build-push.sh

# Or specify a tag
IMAGE_TAG=v1.0.0 ./scripts/build-push.sh
```

---

### 3 — Deploy to EKS with Helm

#### Install External Secrets Operator (once per cluster)

ESO is a cluster-level dependency. Install it before the app chart.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install eso external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait
```

#### Deploy the app

The ServiceAccount already exists in the cluster (Terraform created it). The script only needs the image tag, cluster name, region, and ECR URL:

```bash
IMAGE_TAG=v1.0.0 ./scripts/deploy.sh
```

What the script does internally:
1. Runs `terraform output` to get cluster name, region, and ECR URL
2. Updates your local kubeconfig (`aws eks update-kubeconfig`)
3. Runs `helm upgrade --install` — no IRSA annotation needed (SA is pre-annotated by Terraform)
4. Prints ESO sync status and pod status after deploy

#### Verify manually (optional)

```bash
# ESO sync status — look for READY=True
kubectl get externalsecret -n default

# K8s Secret created by ESO (you never created this — ESO did)
kubectl get secret ccr-customer-complaint-responder-api-key -n default

# Pod status
kubectl get pods -n default
kubectl logs -l app.kubernetes.io/name=customer-complaint-responder -n default
```

---

## API Reference

### `POST /api/v1/complaints`

**Request:**
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
# 1. Update the secret via Terraform (the only place the key ever lives)
export TF_VAR_google_api_key="AIza...new-key..."
terraform apply -var-file=environments/dev.tfvars -chdir=infra

# 2. ESO syncs the new value automatically within 1h.
#    To force immediate sync:
kubectl annotate externalsecret ccr-customer-complaint-responder-api-key \
  force-sync=$(date +%s) --overwrite -n default

# 3. Restart the pod to pick up the updated env var
kubectl rollout restart deployment/ccr-customer-complaint-responder -n default
```

---
