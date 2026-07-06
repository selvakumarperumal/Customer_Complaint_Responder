# Customer Complaint Responder

An AI-powered customer complaint handling system that monitors a support inbox, classifies incoming complaints, and automatically sends professional, empathetic replies using **Google Gemini** and **LangGraph** — all without human intervention.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [The Apps](#the-apps)
  - [Poller](#poller)
  - [Worker](#worker)
- [Deduplication — How Duplicate Replies Are Prevented](#deduplication--how-duplicate-replies-are-prevented)
- [LangGraph AI Pipeline](#langgraph-ai-pipeline)
- [Environment Variables](#environment-variables)
- [Quick Start](#quick-start)
- [Scaling](#scaling)
- [Deployment to AWS EKS (GitOps)](#deployment-to-aws-eks-gitops)
- [Production Infrastructure Lifecycle (Create, Deploy, Destroy)](#production-infrastructure-lifecycle-create-deploy-destroy)
- [Logs](#logs)
- [Tech Stack](#tech-stack)

---

## Overview

When a customer sends a complaint email to your support inbox:

1. The **Poller** detects it via IMAP, pulls only its `uid`, and pushes it to a **Redis Stream**
2. On successful push, the Poller marks the email as `SEEN` to claim it
3. A **Worker** replica pulls the `uid` from the stream and downloads the full email headers/body from IMAP on-demand
4. The Worker checks if the email's `Message-ID` has already been handled, and if not, runs it through the **LangGraph AI agent** (classify → respond)
5. The Worker sends a professional reply via **SMTP**
6. The `Message-ID` is stored in Redis (30-day TTL) so the email is never replied to twice, and the stream entry is acknowledged

The system is designed to scale horizontally — you can run multiple Worker replicas safely because Redis Streams guarantee each email is processed by exactly one worker.

---

## How It Works

### Step-by-step flow

```
Customer sends email
        │
        ▼
Namecheap IMAP inbox  (mail.privateemail.com:993)
        │
        │  Every IMAP_POLL_INTERVAL seconds
        ▼
┌─────────────────────────────────────┐
│             POLLER                  │
│  (always exactly 1 replica)         │
│                                     │
│  1. IMAP SEARCH UNSEEN (UIDs only)  │  ← extremely fast & lightweight
│  2. XADD email:inbound * uid={uid}   │  ← push UID to Redis Stream
│  3. Mark UID as SEEN in mailbox     │  ← claim email only on success
└─────────────────────────────────────┘
        │
        │  Redis Stream  "email:inbound"
        │  Consumer Group "complaint-workers"
        │
        ▼
┌─────────────────────────────────────┐
│             WORKER                  │
│  (scale to any number of replicas)  │
│                                     │
│  1. XREADGROUP (block 5s)           │  ← get UID from stream entry
│  2. Connect to IMAP, fetch by UID   │  ← on-demand download & parsing
│  3. Check Redis: EXISTS             │
│       replied:{message_id}          │  ← skip if already handled
│  4. LangGraph AI pipeline:          │
│       classify complaint type       │
│       generate professional reply   │
│  5. Send reply via SMTP             │
│  6. SET replied:{message_id} 1      │  ← mark as done (30-day TTL)
│  7. XACK stream entry               │  ← remove from Pending Entry List
└─────────────────────────────────────┘
        │
        ▼
Customer receives AI-generated reply
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         Docker Compose                           │
│                                                                  │
│  ┌──────────┐     XADD      ┌──────────────────────────────┐    │
│  │  poller  │ ─────────────▶│   Redis 7                    │    │
│  │ 1 replica│               │   Stream: email:inbound      │    │
│  └──────────┘               │   Keys:   replied:{msg_id}   │    │
│       │                     └──────────────────────────────┘    │
│       │ IMAP poll                        │ XREADGROUP           │
│       │ (SSL:993)                        ▼                      │
│       │                     ┌──────────────────────────────┐    │
│       │                     │  worker  │  worker  │ worker  │   │
│       │                     │ replica1 │ replica2 │ replica3│   │
│       │                     └──────────────────────────────┘    │
│       │                                  │ SMTP                 │
│  Namecheap                               │ (TLS:587)            │
│  Private Email ◀─────────────────────────┘                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Why not poll IMAP from multiple replicas?

IMAP has no locking mechanism. If two pollers both call `SEARCH UNSEEN` at the same moment, they will both see the same unread emails before either has had a chance to mark them `SEEN`. The result: every email gets processed and replied to twice.

**Solution:** The Poller is always `replicas: 1`. It's cheap (just I/O-bound polling), so one replica is more than enough. The expensive work (LLM inference, SMTP) happens in the Workers, which are the ones you scale.

---

## Project Structure

```
Customer_Complaint_Responder/
├── docker-compose.yml          # Orchestrates all services
├── .env                        # Your credentials (never commit this)
├── .env.example                # Template — copy to .env and fill in
└── apps/
    ├── poller/                 # IMAP poller microservice
    │   ├── Dockerfile
    │   ├── pyproject.toml
    │   └── app/
    │       ├── core/
    │       │   └── config.py   # IMAP + Redis settings
    │       └── main.py         # Poll loop
    └── worker/                 # AI worker microservice
        ├── Dockerfile
        ├── pyproject.toml
        └── app/
            ├── core/
            │   └── config.py   # Gemini + SMTP + Redis settings
            ├── services/
            │   ├── agent/
            │   │   ├── agent.py    # LangGraph graph definition
            │   │   └── prompts.py  # Classify + respond prompts
            │   └── email.py        # SMTP sender
            └── main.py             # Stream consumer loop
```

---

## The Apps

### Poller

**Location:** `apps/poller/`  
**Replicas:** Always **1** — never scale this above 1  
**Dependencies:** `imap-tools`, `redis`, `pydantic-settings`

The Poller runs a simple infinite loop:

```
while True:
    connect to IMAP (SSL)
    get all UNSEEN email UIDs          # fast lookup (no content download)
    for each uid:
        XADD email:inbound * uid=<uid> # publish lightweight UID to Redis
        mark SEEN on success           # claim email only after queued
    sleep(IMAP_POLL_INTERVAL)
```

**Key design choice — Lazy fetching and at-least-once queueing:**  
The Poller uses a lightweight IMAP search for unseen email UIDs, pushes them to Redis Stream first, and only marks them `\Seen` on the mail server upon a successful `XADD`. This avoids downloading large MIME bodies inside the poller. If a failure occurs before the message is queued, it remains unseen and is retried. Once in the stream, the worker pool handles the retrieval and processing.

---

### Worker

**Location:** `apps/worker/`  
**Replicas:** **2 by default**, safe to scale to any number  
**Dependencies:** `langchain`, `langchain-google-genai`, `langgraph`, `redis`, `pydantic-settings`

The Worker runs a blocking Redis Stream consumer loop:

```
on startup:
    XGROUP CREATE email:inbound complaint-workers $ MKSTREAM  # idempotent

while True:
    messages = XREADGROUP GROUP complaint-workers <hostname> COUNT 10 BLOCK 5000
    for each message:
        connect to IMAP, fetch message by UID
        if EXISTS replied:{message_id}:
            XACK and skip             # already handled
        run LangGraph AI pipeline     # classify + respond
        send SMTP reply               # Namecheap outgoing mail
        SET replied:{message_id} 1 EX 2592000   # 30-day dedupe key
        XACK                          # remove from Pending Entry List
```

Each Worker uses its **container hostname** as the consumer name (`socket.gethostname()`). Docker assigns a unique hostname to each container, so replicas automatically register as distinct consumers in the group without any manual configuration.

---

## Deduplication — How Duplicate Replies Are Prevented

Three independent layers work together to ensure each complaint gets exactly one reply:

| Layer | Where | Mechanism | Guards Against |
|---|---|---|---|
| **1. IMAP claim** | Poller | `mark_seen=True` on fetch | Two poller restarts racing on the same UNSEEN email |
| **2. Stream delivery** | Redis | `XREADGROUP` consumer groups | Two worker replicas pulling the same stream entry |
| **3. Redis dedupe key** | Worker | `EXISTS replied:{Message-ID}` | Any edge case redelivery, crash recovery, or stream replay |

The `Message-ID` email header is the unique identifier used for the dedupe key. It is set by the sender's mail client and is guaranteed to be globally unique per RFC 5322.

**What happens if a Worker crashes mid-flight?**  
The `XACK` command is only sent after the reply has been successfully sent and the dedupe key has been written. If a worker crashes before `XACK`, the stream entry stays in the **Pending Entry List (PEL)**. On restart, another worker can reclaim it via `XAUTOCLAIM`. Since the dedupe key was never written, the email will be processed again — which is the safe fallback.

---

## LangGraph AI Pipeline

The Worker runs each complaint through a two-node LangGraph graph:

```
START
  │
  ▼
[classify]  ── Gemini ──▶  complaint_type:
                           "delivery" | "refund" | "product issue" | "other"
  │
  ▼
[respond]   ── Gemini ──▶  response: professional, empathetic reply text
  │
  ▼
END
```

**Thread-aware conversation history:**  
Conversation history is stored persistently inside the customer's email mailbox folder (IMAP). When a new email arrives, the worker normalizes the subject (removing prefixes like "Re:") to find all emails belonging to the same thread. It sorts them chronologically and compiles a clean, formatted conversation history transcript (omitting quoted reply blocks) to provide full context to the Gemini AI agent.

**Prompts** (in `apps/worker/app/services/agent/prompts.py`):

- **Classify prompt** — asks the model to classify the conversation thread into one of: `delivery`, `refund`, `product issue`, `other`
- **Response prompt** — asks the model to generate a single professional, empathetic support reply addressing the latest request in the thread history

---

## Environment Variables

Copy `.env.example` to `.env` and fill in your real values:

```bash
cp .env.example .env
```

| Variable | Used By | Description | Default |
|---|---|---|---|
| `GEMINI_API_KEY` | worker | Google Gemini API key | *(required)* |
| `MISTRAL_API_KEY` | worker | Mistral API key | *(optional)* |
| `HOST` | both | Private Email server hostname | `mail.privateemail.com` |
| `PRIVATE_MAIL_EMAIL_ID` | both | Email address to poll/send | *(required)* |
| `PRIVATE_MAIL_PASSWORD` | both | Email account password | *(required)* |
| `IMAP_PORT` | both | IMAP server port (SSL) | `993` |
| `IMAP_POLL_INTERVAL` | poller | Seconds between inbox checks | `60` |
| `SMTP_PORT` | worker | SMTP port (STARTTLS) | `587` |
| `FROM_NAME` | worker | Support reply display name | `Customer Support` |
| `REDIS_URL` | both | Redis connection string | `redis://redis:6379/0` |
| `REDIS_STREAM_NAME` | both | Stream key name | `email:inbound` |
| `REDIS_CONSUMER_GROUP` | worker | Consumer group name | `complaint-workers` |

> **Note:** `REDIS_URL` is automatically set to `redis://redis:6379/0` by `docker-compose.yml` via the `environment:` block, so you don't need to set it in `.env` for Docker usage.

---

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) + [Docker Compose](https://docs.docker.com/compose/)
- A Namecheap Private Email account with an inbox to monitor
- A [Google AI Studio](https://aistudio.google.com) API key (Gemini)

### 1. Clone and configure

```bash
git clone <your-repo-url>
cd Customer_Complaint_Responder

cp .env.example .env
# Open .env and fill in your real credentials
```

### 2. Build images

```bash
docker compose build
```

### 3. Start all services

```bash
docker compose up -d
```

This starts:
- `redis` — Redis 7 with AOF persistence
- `poller` — 1 replica, polls your inbox every 60 seconds
- `worker` — 2 replicas, processes complaints from the stream

### 4. Verify everything is running

```bash
docker compose ps
```

Expected output:
```
NAME                          STATUS    PORTS
customer_complaint...-redis   Up        0.0.0.0:6379->6379/tcp
customer_complaint...-poller  Up
customer_complaint...-worker  Up (x2)
```

### 5. Send a test email

Send an email to your support inbox (the address in `PRIVATE_MAIL_EMAIL_ID`). Within `IMAP_POLL_INTERVAL` seconds you should see:

```
# In poller logs:
2026-06-23T13:30:01 [poller] INFO Published UID 45 → stream entry 1234567890-0 and marked SEEN.

# In worker logs:
2026-06-23T13:30:02 [worker/abc123] INFO Received job for email UID 45 (stream_id=1234567890-0)
2026-06-23T13:30:03 [worker/abc123] INFO Fetched email from customer@example.com (subject='Order not arrived', message_id=<...>)
2026-06-23T13:30:03 [worker/abc123] INFO Running LangGraph complaint handler for thread_id=...
2026-06-23T13:30:05 [worker/abc123] INFO Classified as: delivery
2026-06-23T13:30:06 [worker/abc123] INFO Successfully sent email to customer@example.com
2026-06-23T13:30:06 [worker/abc123] INFO Marked Message-ID <...> as replied (TTL=2592000s).
```

### 6. Stop

```bash
docker compose down        # stops containers, keeps Redis data
docker compose down -v     # also deletes the Redis volume (wipes stream + dedupe keys)
```

---

## Scaling

The Worker is the only service that should be scaled. The Poller must always stay at 1 replica.

```bash
# Run 4 worker replicas
docker compose up -d --scale worker=4

# Check active consumers in the Redis stream group
docker compose exec redis redis-cli XINFO CONSUMERS email:inbound complaint-workers
```

**For Kubernetes autoscaling:** Use a KEDA `ScaledObject` targeting the `email:inbound` stream length to automatically scale the Worker deployment based on queue depth. Keep the Poller as a standard `Deployment` with `replicas: 1`.

---

## Deployment to AWS EKS (GitOps)

The system is configured for production deployment on **AWS EKS** using **ArgoCD GitOps** (App-of-Apps pattern) and **AWS IAM Pod Identity / IRSA** to secure secret syncing.

### EKS Architecture

```
                     ┌──────────────────────────────────────────────┐
                     │                 AWS Cloud                    │
                     │                                              │
                     │  ┌──────────────────┐  ┌──────────────────┐  │
                     │  │ Secrets Manager  │  │ SSM Param Store  │  │
                     │  └────────┬─────────┘  └────────┬─────────┘  │
                     │           │                     │            │
                     └───────────┼─────────────────────┼────────────┘
                                 │ Sync                │ Sync
                                 ▼                     ▼
┌────────────────────────────────┼─────────────────────┼────────────┐
│ Kubernetes (EKS Cluster)       │                     │            │
│                                │                     │            │
│   Namespace: external-secrets  │                     │            │
│   ┌────────────────────────────▼─────────────────────▼────────┐   │
│   │               external-secrets operator                   │   │
│   └────────────────────────────┬─────────────────────┬────────┘   │
│                                │ Writes              │ Writes     │
│                                ▼                     ▼            │
│   Namespace: complaint-responder                                  │
│   ┌────────────────────────────┐                     │            │
│   │ Secret: ccr-secrets        │                     │            │
│   └────────────┬───────────────┘                     │            │
│                │ envFrom                             ▼            │
│                │           ┌─────────────────────────┐            │
│                ├──────────▶│ Secret: ccr-ssm-params  │            │
│                │           └────────────┬────────────┘            │
│                │                        │ envFrom                 │
│                ▼                        ▼                         │
│       ┌──────────────┐         ┌──────────────┐                   │
│       │    poller    │         │    worker    │                   │
│       │  (1 replica) │         │ (2+ replicas)│                   │
│       └──────────────┘         └──────────────┘                   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### 1. Root Bootstrapping (App-of-Apps)

Deployment is managed via a parent Helm chart `argocd/apps` which manages three child Applications in the cluster.

Apply the root application directly using `kubectl`:
```bash
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD coordinates the resource rollouts in sequential **Sync Waves**:
1. **Wave 1 (`platform-baseline`)**: Deploys controllers (`external-secrets` and `karpenter`).
2. **Wave 2 (`karpenter-config`)**: Provisions Karpenter configuration settings (`NodePool` and `EC2NodeClass`).
3. **Wave 3 (`customer-complaint-responder`)**: Deploys the main application (`redis`, `poller`, `worker`).

### 2. AWS Secrets Manager & SSM Parameter Store Syncing

The application deployment templates are fully integrated with AWS Secrets Manager and SSM Parameter Store using the **ExternalSecrets** operator.
* **Credentials**: Synced from AWS Secrets Manager secret `${project_name}-secrets` (Google Gemini API key, Mistral API key, IMAP credentials) into a Kubernetes Secret named `ccr-secrets`.
* **Configurations**: Synced from SSM parameters (port numbers, Redis stream names, consumer group settings) into a Kubernetes Secret named `ccr-ssm-params`.
* **Security**: Syncing is authorized using EKS ServiceAccounts bound to AWS IAM Roles (via IRSA or EKS Pod Identity) matching policies defined in Terraform (`infra/`).

### 3. Dynamic Node Scaling (Karpenter)

The `karpenter-config` chart configures Karpenter v1.13.0 to handle autoscaling for your worker node pool:
* **Instances**: Karpenter scales on c-class instances of generation `3` and newer (e.g. `c5`, `c6i`), supporting both `amd64` and `arm64` CPU architectures.
  > [!IMPORTANT]
  > Because the custom application docker images (`poller`, `worker`) are built only for the `amd64` architecture, the helm values configure a `nodeSelector` (`kubernetes.io/arch: amd64`) for all pods. This prevents scheduling them on cheaper `arm64` instances which would crash with an `exec /usr/bin/uv: exec format error`. If you build multi-arch images (e.g., using `docker buildx`), you can remove this selector constraint.
* **OS**: Nodes run EKS-optimized **Bottlerocket OS** with optimized EBS configurations (`3Gi` xvda root control volume, `5Gi` xvdb container storage).
* **Consolidation**: Configured with disruption budgets to prune underutilized nodes and drift configurations safely during low traffic.

---

## Production Infrastructure Lifecycle (Create, Deploy, Destroy)

Below is the step-by-step lifecycle workflow for managing the production environment on AWS EKS.

### 1. Create Infrastructure (Terraform)

#### A. Initialize the State Backend Bucket
Navigating to the `statebucket` module to create the S3 bucket and DynamoDB lock table for storing Terraform state:
```bash
cd statebucket/
terraform init
terraform apply
cd ..
```
*Note: This generates `infra/backend.hcl` automatically, which configures the remote backend for the main infrastructure module.*

#### B. Deploy the Infrastructure
1. Create a `terraform.tfvars` file under `infra/` with your credentials:
   ```hcl
   aws_region            = "ap-south-1"
   project_name          = "complaint-responder"
   google_api_key        = "YOUR_GEMINI_API_KEY"
   mistral_api_key       = "YOUR_MISTRAL_API_KEY"
   private_mail_email_id = "support@yourdomain.com"
   private_mail_password = "YOUR_MAIL_PASSWORD"
   ```
2. Apply the Terraform configurations:
   ```bash
   cd infra/
   terraform init -backend-config=backend.hcl
   terraform apply
   cd ..
   ```
   This provisions the VPC, EKS cluster, ECR registries, AWS Secrets Manager credentials, SSM parameter values, and bootstraps ArgoCD in the cluster.

#### C. Verify the Provisioned Infrastructure

To ensure that all resources are correctly provisioned and ready, perform the following verification checks:

##### 1. Connect to the EKS Cluster
Configure `kubectl` to connect to your new EKS cluster:
```bash
aws eks update-kubeconfig --region ap-south-1 --name complaint-responder-cluster
```
*(Adjust the `--region` and `--name` flags if you used different values in `terraform.tfvars`.)*

##### 2. Verify Cluster Status and Nodes
Verify that the cluster is active and that the managed system node group has successfully launched:
```bash
# Check EKS cluster status (should output "ACTIVE")
aws eks describe-cluster --name complaint-responder-cluster --query "cluster.status" --output text

# List cluster nodes (should show the system node in 'Ready' status)
kubectl get nodes -o wide
```

##### 3. Verify AWS Secrets Manager & SSM Parameter Store
Ensure the application secrets and configuration parameters are successfully stored in AWS, and verify their retrieved values/keys:

```bash
# Retrieve metadata of the secret
aws secretsmanager describe-secret --secret-id complaint-responder-secrets

# Retrieve the JSON secret value (verify the keys like google_api_key exist)
aws secretsmanager get-secret-value --secret-id complaint-responder-secrets --query SecretString --output text

# List all SSM parameters with their decrypted values in a table
aws ssm get-parameters-by-path --path "/complaint-responder/" --with-decryption --query "Parameters[*].[Name,Value]" --output table
```

##### 4. Verify Synced Kubernetes Secrets (Post-Deployment)
Once the application charts are applied via ArgoCD, verify that the **ExternalSecrets** operator has successfully mapped the AWS secrets and SSM parameters to native Kubernetes Secrets in the target namespace:
```bash
# Check status of ExternalSecrets (should show SecretSynced)
kubectl get externalsecrets -n complaint-responder

# Verify the synced Kubernetes secrets are present
kubectl get secrets ccr-secrets ccr-ssm-params -n complaint-responder

# Verify the keys populated in the ccr-secrets Secret
kubectl get secret ccr-secrets -n complaint-responder -o jsonpath="{.data}" | jq 'keys' 2>/dev/null || kubectl get secret ccr-secrets -n complaint-responder -o jsonpath="{.data}"
```

##### 5. Verify ECR Repositories
Check that the Amazon ECR repositories are ready to receive container images:
```bash
aws ecr describe-repositories --query "repositories[].repositoryName"
```
*Expected repositories:*
- `complaint-responder-ecr/poller`
- `complaint-responder-ecr/worker`

##### 6. Verify ArgoCD Deployment
Confirm that the ArgoCD components have bootstrapped successfully in the cluster:
```bash
# Check the status of ArgoCD pods (should show Running/Completed status)
kubectl get pods -n argocd

# Retrieve the initial administrator password for the ArgoCD web console
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
You can access the ArgoCD dashboard by port-forwarding the service:
```bash
# Forward port 8080 to the ArgoCD API Server
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
*Open `https://localhost:8080` in your web browser and sign in using username `admin` and the retrieved password.*

---

### 2. Build and Deploy Application (Docker + ArgoCD)

#### A. Build and Push Container Images to ECR
1. Log in to your AWS ECR Registry:
   ```bash
   aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com
   ```
2. Build and tag the Poller and Worker images.
   
   If you want to run pods on both `amd64` and `arm64` nodes (supporting Karpenter's dual-architecture settings), build multi-arch images using Docker `buildx`:
   ```bash
   # Initialize buildx driver if you haven't already
   docker buildx create --use
   
   # Build & push Poller (multi-arch)
   docker buildx build --platform linux/amd64,linux/arm64 -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest --push apps/poller/

   # Build & push Worker (multi-arch)
   docker buildx build --platform linux/amd64,linux/arm64 -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest --push apps/worker/
   ```
   Otherwise, standard builds will only support `amd64` hosts:
   ```bash
   # Build & push Poller (default architecture)
   docker build -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest apps/poller/
   docker push <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest

   # Build & push Worker (default architecture)
   docker build -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest apps/worker/
   docker push <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest
   ```

#### B. Bootstrap GitOps Deployment
Apply the root parent ArgoCD Application to trigger the App-of-Apps syncing:
```bash
kubectl apply -f argocd/app-of-apps.yaml
```
This triggers ArgoCD to pull configurations from the `main` branch, setup namespaces, configure Karpenter, sync EKS ExternalSecrets, and deploy the application pods.

---

### 3. Destroy Infrastructure Properly (Tear Down)

> [!CAUTION]
> **Orphaned Karpenter Node Leak Warning**:
> Running `terraform destroy` directly on your infrastructure **will get stuck or fail**. Because Karpenter dynamically provisions worker EC2 instances *outside* of Terraform, destroying the EKS cluster first will leave these nodes orphaned. The active ENIs (elastic network interfaces) and Security Groups attached to these orphaned nodes will block Terraform from deleting the VPC, resulting in a deadlock.

Follow this strict, fail-safe destruction sequence:

#### Step 1: Delete all Karpenter-managed resources first
Delete the root GitOps application to clean up the cluster workloads. This forces Karpenter to drain and terminate all EC2 worker instances it launched:
```bash
kubectl delete -f argocd/app-of-apps.yaml
```

Verify that all ArgoCD applications have been fully removed:
```bash
kubectl get applications -n argocd
# Expected: "No resources found in argocd namespace."
```

Wait until all Karpenter-managed worker nodes are fully terminated. You can verify this by checking that only your managed system node group remains:
```bash
kubectl get nodes
```

#### Step 2: Clean and Force-Delete ECR Repositories
Terraform will fail to delete ECR registries if they still contain container images (tags or untagged layers). Force-delete them via the AWS CLI before destroying the Terraform configuration:
```bash
aws ecr delete-repository --repository-name complaint-responder-ecr/poller --force --region ap-south-1
aws ecr delete-repository --repository-name complaint-responder-ecr/worker --force --region ap-south-1
```
*(If a repository has already been deleted or is missing, you can safely ignore any `RepositoryNotFoundException` errors).*

##### FAQ: What if I already deleted the ECR repository manually?
No issue. `terraform destroy` handles this gracefully.

Why this is safe:
- Terraform refreshes state against AWS before destroy actions.
- If ECR returns `RepositoryNotFoundException`, Terraform treats the repository as already gone and removes it from state.
- Terraform will not attempt a delete call for a repository that no longer exists.

Practical note:
- Run `terraform plan -destroy` first to verify what remains.
- `terraform state rm` is optional in this case, not required.

#### Step 3: Destroy Core EKS and VPC Infrastructure (Terraform)
Make sure to source your environment variables from `.envrc` so Terraform does not prompt you for the API keys or mail credentials during destruction:
```bash
cd infra/
source .envrc
terraform destroy -auto-approve
cd ..
```
*(If a state lock is left over from an interrupted run, retrieve the Lock ID from the error output and run: `source .envrc && echo "yes" | terraform force-unlock <LOCK_ID>`)*

#### Step 4: Empty S3 Remote State Bucket Versions
Since the state bucket has versioning enabled, AWS prevents bucket deletion while it contains old versions and delete markers. Empty all versions and delete markers from the bucket:
```bash
# Replace <YOUR_AWS_ACCOUNT_ID> with your actual AWS account number
# 1. Delete all object versions
aws s3api delete-objects \
  --bucket ccr-tfstate-bucket-001-<YOUR_AWS_ACCOUNT_ID> \
  --delete "$(aws s3api list-object-versions \
              --bucket ccr-tfstate-bucket-001-<YOUR_AWS_ACCOUNT_ID> \
              --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
              --output json)"

# 2. Delete all delete markers
aws s3api delete-objects \
  --bucket ccr-tfstate-bucket-001-<YOUR_AWS_ACCOUNT_ID> \
  --delete "$(aws s3api list-object-versions \
              --bucket ccr-tfstate-bucket-001-<YOUR_AWS_ACCOUNT_ID> \
              --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
              --output json)"
```

#### Step 5: Destroy the State Bucket Configuration (Terraform)
Once the bucket is completely empty, destroy the S3 bucket and local state bucket configurations:
```bash
cd statebucket/
terraform destroy -auto-approve
cd ..
```

---

## Logs

Watch all services in real time:

```bash
docker compose logs -f
```

Watch a specific service:

```bash
docker compose logs -f poller
docker compose logs -f worker
```

Inspect the Redis stream directly:

```bash
# Number of entries in the stream
docker compose exec redis redis-cli XLEN email:inbound

# Last 10 entries
docker compose exec redis redis-cli XREVRANGE email:inbound + - COUNT 10

# Pending (unacknowledged) messages in the consumer group
docker compose exec redis redis-cli XPENDING email:inbound complaint-workers - + 10

# Check if a specific Message-ID has been replied to
docker compose exec redis redis-cli EXISTS "replied:<message-id>"
```

---

## Tech Stack

| Component | Technology |
|---|---|
| AI Model | Google Gemini (`gemini-3.5-flash`) |
| AI Orchestration | LangGraph + LangChain |
| Message Queue | Redis 7 Streams (consumer groups) |
| IMAP Client | `imap-tools` |
| SMTP | Python `smtplib` (STARTTLS) |
| Email Provider | Namecheap Private Email |
| Config | `pydantic-settings` |
| Package Manager | `uv` |
| Container Runtime | Docker Compose |
