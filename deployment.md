# EKS Deployment and Infrastructure Lifecycle Guidelines

This document details the step-by-step guidelines for provisioning infrastructure, building applications, deploying via GitOps (ArgoCD), and safely tearing down the EKS resources for the **Customer Complaint Responder** project.

---

## EKS & GitOps Deployment Architecture

The production environment runs on **Amazon EKS** using a GitOps model managed by **ArgoCD**. Application configuration and environment variables are retrieved dynamically from **AWS Secrets Manager** and **SSM Parameter Store** via the **ExternalSecrets** operator.

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

---

## Prerequisites

Before starting, ensure you have the following tools installed and configured:
* **AWS CLI** (v2.x) with admin credentials configured (`aws configure`).
* **Terraform** (v1.5+)
* **kubectl** matching your cluster's Kubernetes version.
* **Helm** (v3.x)
* **Docker** with **Docker Buildx** enabled for multi-architecture builds.

---

## 1. Create Infrastructure (Terraform)

Infrastructure provisioning is split into two phases: creating the remote state backend (S3/DynamoDB) and deploying the EKS cluster, VPC, and related AWS services.

### Phase A: Initialize the State Backend Bucket
We store the Terraform state remotely in an S3 bucket with versioning enabled and lock state changes using a DynamoDB table.

1. Navigate to the `statebucket` folder:
   ```bash
   cd statebucket/
   ```
2. Initialize and deploy:
   ```bash
   terraform init
   terraform apply -auto-approve
   ```
   *Note: This automatically creates the S3 bucket, DynamoDB lock table, and generates the remote backend configuration file (`infra/backend.hcl`).*
3. Return to the root directory:
   ```bash
   cd ..
   ```

### Phase B: Deploy EKS and AWS Resources
1. Create a `terraform.tfvars` file under the `infra/` directory containing your variables:
   ```hcl
   aws_region            = "ap-south-1"
   project_name          = "complaint-responder"
   google_api_key        = "YOUR_GEMINI_API_KEY"
   mistral_api_key       = "YOUR_MISTRAL_API_KEY"
   private_mail_email_id = "support@yourdomain.com"
   private_mail_password = "YOUR_MAIL_PASSWORD"
   ```
2. Navigate to the `infra` directory:
   ```bash
   cd infra/
   ```
3. Initialize Terraform with the S3 backend settings:
   ```bash
   terraform init -backend-config=backend.hcl
   ```
4. Deploy the infrastructure:
   ```bash
   terraform apply -auto-approve
   ```
   This will provision:
   * **VPC**: Multi-AZ public and private subnets, NAT Gateways.
   * **EKS Cluster**: EKS control plane and a managed system node group (using `t3.medium` instances for ArgoCD and Karpenter controllers).
   * **ECR Registries**: Repositories for the `poller` and `worker` images.
   * **SSM Parameter Store & AWS Secrets Manager**: Automatically populated with variables and API keys from your `.tfvars` file.
   * **ArgoCD**: Bootstrapped via Helm in the `argocd` namespace.
5. Return to the project root:
   ```bash
   cd ..
   ```

---

## 2. Build and Deploy Application (Docker + ArgoCD)

Once your infrastructure is ready, compile your application container images, push them to Amazon ECR, and deploy using GitOps.

### Step A: Build & Push Images to ECR
1. Retrieve ECR login credentials and authenticate Docker:
   ```bash
   aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com
   ```
2. Build and push container images.
   
   #### Option 1: Multi-Architecture Builds (Recommended)
   By default, Karpenter is configured to scale nodes using both `amd64` and `arm64` CPU architectures. To deploy pods on both node types, use Docker `buildx` to create multi-arch images:
   ```bash
   # Initialize and select a buildx driver
   docker buildx create --use

   # Build & push Poller
   docker buildx build --platform linux/amd64,linux/arm64 -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest --push apps/poller/

   # Build & push Worker
   docker buildx build --platform linux/amd64,linux/arm64 -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest --push apps/worker/
   ```

   #### Option 2: Single-Architecture Builds (amd64 only)
   If you build standard `amd64` images, you **must** configure a node selector to prevent pods from scheduling on `arm64` instances (which would crash with `exec format error`):
   ```bash
   # Build & push Poller
   docker build -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest apps/poller/
   docker push <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/poller:latest

   # Build & push Worker
   docker build -t <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest apps/worker/
   docker push <YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/complaint-responder-ecr/worker:latest
   ```
   *Note: In `helm/Customer-Complaint-Responder/values.yaml`, ensure `nodeSelector` is set to `kubernetes.io/arch: amd64` if building using Option 2.*

### Step B: Bootstrap GitOps (App-of-Apps)
Deploy the parent application to bootstrap all Kubernetes resources:
```bash
kubectl apply -f argocd/app-of-apps.yaml
```
ArgoCD uses **Sync Waves** to coordinate order:
1. **Wave 1 (`platform-baseline`)**: Installs the `external-secrets` and `karpenter` operators.
2. **Wave 2 (`karpenter-config`)**: Provisions Karpenter configuration settings (`NodePool` and `EC2NodeClass`).
3. **Wave 3 (`customer-complaint-responder`)**: Deploys the main application (`redis`, `poller`, `worker` pods, services, and `ExternalSecrets`).

---

## 3. Verify the Deployment

Ensure that all resources are correctly provisioned, running, and synchronized.

### A. Access EKS Cluster
Configure local `kubectl` to target your new EKS cluster:
```bash
aws eks update-kubeconfig --region ap-south-1 --name complaint-responder-cluster
```

### B. Verify Core Components
```bash
# Check cluster node status (should list managed system nodes)
kubectl get nodes -o wide

# Check status of all applications in ArgoCD
kubectl get applications -n argocd

# Verify all pods are running in the target namespace
kubectl get pods -n complaint-responder -o wide
```

### C. Verify ExternalSecrets Sync
Ensure EKS can safely fetch secrets and parameters from AWS Secrets Manager and SSM Parameter Store:
```bash
# Verify the ExternalSecrets sync status (should show STATUS = SecretSynced)
kubectl get externalsecrets -n complaint-responder

# Verify target Kubernetes secrets were created
kubectl get secrets ccr-secrets ccr-ssm-params -n complaint-responder
```

---

## 4. Safe Infrastructure Teardown (Tear Down)

> [!CAUTION]
> **Orphaned Karpenter Node Leak Warning**:
> Running `terraform destroy` directly **will deadlock or fail**. Because Karpenter dynamically provisions worker EC2 instances outside of Terraform, destroying the EKS cluster first will leave these nodes orphaned. The active network interfaces (ENIs) and security groups attached to them will block Terraform from deleting the VPC, leaking EC2 instances.

Follow this strict, fail-safe destruction sequence:

### Step 1: Delete Kubernetes Applications First
Delete the parent ArgoCD application. This triggers a cascading deletion of the application, platform configs, and operators. This forces Karpenter to drain and terminate all EC2 worker instances it launched:
```bash
kubectl delete -f argocd/app-of-apps.yaml
```
Verify that all ArgoCD apps have been completely removed:
```bash
kubectl get applications -n argocd
# Expected: "No resources found in argocd namespace."
```
Wait until all Karpenter-managed worker nodes are fully terminated. Only the managed system node group should remain:
```bash
kubectl get nodes
```

### Step 2: Empty ECR Registries
Terraform will fail to delete ECR registries if they still contain container images (tagged or untagged layers). You can delete all images using the provided Python script:
```bash
uv run --project destroy_essentials destroy_essentials/delete_ecr_repo.py
```
*(Alternatively, you can force-delete the repositories via the AWS CLI:)*
```bash
aws ecr delete-repository --repository-name complaint-responder-ecr/poller --force --region ap-south-1
aws ecr delete-repository --repository-name complaint-responder-ecr/worker --force --region ap-south-1
```

### Step 3: Destroy Core EKS and VPC Infrastructure (Terraform)
Make sure to source your environment variables (e.g. from `.envrc` or shell env) so Terraform does not prompt you for inputs during destruction:
```bash
cd infra/
source .envrc
terraform destroy -auto-approve
cd ..
```
*(If a state lock is left over from an interrupted run, retrieve the Lock ID from the error output and run: `terraform force-unlock <LOCK_ID>`)*

### Step 4: Empty S3 Remote State Bucket Versions
Since the state bucket has versioning enabled, AWS prevents bucket deletion while it contains old versions, delete markers, or incomplete multipart uploads. Clean the bucket using the provided Python script:
```bash
uv run --project destroy_essentials destroy_essentials/delete_statebucket.py
```
*(Alternatively, if you prefer the AWS CLI, replace `<YOUR_AWS_ACCOUNT_ID>` with your AWS account number to empty the bucket manually:)*
```bash
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

### Step 5: Destroy the State Bucket Configuration (Terraform)
Once the bucket is completely empty, navigate to the `statebucket` folder and destroy the S3 bucket configuration:
```bash
cd statebucket/
terraform destroy -auto-approve
cd ..
```
